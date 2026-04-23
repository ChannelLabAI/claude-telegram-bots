"""Core Notion File Upload logic — no MCP dependency.

Implements the 3-step Notion File Upload API flow (API version 2026-03-11):
1. Create file upload object
2. Send file content
3. Attach to page as block
"""

import mimetypes
import os
import time
from pathlib import Path

import requests

NOTION_API_BASE = "https://api.notion.com/v1"
NOTION_VERSION = "2026-03-11"
MAX_FILE_SIZE = 20 * 1024 * 1024  # 20 MB

# Map file extensions to Notion block types
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"}
PDF_EXTENSIONS = {".pdf"}

# Extra MIME types not always in Python's mimetypes registry
EXTRA_MIME_TYPES = {
    ".pdf": "application/pdf",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
    ".webp": "image/webp",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ".txt": "text/plain",
    ".csv": "text/csv",
    ".zip": "application/zip",
}


def detect_content_type(file_path: str) -> str:
    """Detect MIME content type from file extension."""
    ext = Path(file_path).suffix.lower()
    if ext in EXTRA_MIME_TYPES:
        return EXTRA_MIME_TYPES[ext]
    mime, _ = mimetypes.guess_type(file_path)
    return mime or "application/octet-stream"


def get_block_type(file_path: str) -> str:
    """Determine Notion block type based on file extension.

    Returns 'image' for images, 'pdf' for PDFs, 'file' for everything else.
    """
    ext = Path(file_path).suffix.lower()
    if ext in IMAGE_EXTENSIONS:
        return "image"
    if ext in PDF_EXTENSIONS:
        return "pdf"
    return "file"


def normalize_page_id(page_id: str) -> str:
    """Normalize a Notion page ID — strip dashes for API use, accept both formats."""
    return page_id.replace("-", "")


def validate_file(file_path: str) -> tuple[bool, str]:
    """Validate file exists and is within size limit.

    Returns (ok, error_message). If ok is True, error_message is empty.
    """
    path = Path(file_path)
    if not path.exists():
        return False, f"File not found: {file_path}"
    if not path.is_file():
        return False, f"Not a file: {file_path}"
    size = path.stat().st_size
    if size > MAX_FILE_SIZE:
        size_mb = size / (1024 * 1024)
        return False, f"File too large: {size_mb:.1f} MB (max 20 MB)"
    if size == 0:
        return False, f"File is empty: {file_path}"
    return True, ""


def _headers(token: str, content_type: str = "application/json") -> dict:
    """Build standard Notion API headers."""
    h = {
        "Authorization": f"Bearer {token}",
        "Notion-Version": NOTION_VERSION,
    }
    if content_type:
        h["Content-Type"] = content_type
    return h


def _api_call_with_retry(method: str, url: str, token: str, **kwargs) -> requests.Response:
    """Make an API call with one retry on 429."""
    func = getattr(requests, method)
    resp = func(url, **kwargs)
    if resp.status_code == 429:
        time.sleep(1)
        resp = func(url, **kwargs)
    return resp


def _check_response(resp: requests.Response, step: str) -> dict:
    """Check response and raise descriptive errors."""
    if resp.status_code in (401, 403):
        raise PermissionError(
            f"{step}: Notion token invalid or missing permissions "
            f"(HTTP {resp.status_code})"
        )
    if resp.status_code == 429:
        raise RuntimeError(f"{step}: Rate limited by Notion API even after retry")
    if not resp.ok:
        body = resp.text[:500]
        raise RuntimeError(
            f"{step}: Notion API error HTTP {resp.status_code} — {body}"
        )
    return resp.json()


def create_file_upload(filename: str, content_type: str, token: str) -> dict:
    """Step 1: Create a file upload object."""
    url = f"{NOTION_API_BASE}/file_uploads"
    payload = {"name": filename, "content_type": content_type}
    resp = _api_call_with_retry(
        "post", url, token,
        headers=_headers(token),
        json=payload,
    )
    return _check_response(resp, "Step 1 (create file upload)")


def send_file_content(upload_id: str, file_path: str, token: str) -> dict:
    """Step 2: Send the actual file content."""
    url = f"{NOTION_API_BASE}/file_uploads/{upload_id}/send"
    headers = {
        "Authorization": f"Bearer {token}",
        "Notion-Version": NOTION_VERSION,
    }
    with open(file_path, "rb") as f:
        files = {"file": (Path(file_path).name, f)}
        resp = _api_call_with_retry(
            "post", url, token,
            headers=headers,
            files=files,
        )
    return _check_response(resp, "Step 2 (send file content)")


def attach_to_page(
    page_id: str, upload_id: str, block_type: str, token: str, caption: str = ""
) -> dict:
    """Step 3: Append uploaded file to a Notion page as a block."""
    url = f"{NOTION_API_BASE}/blocks/{page_id}/children"

    block_content: dict = {
        "type": "file_upload",
        "file_upload": {"id": upload_id},
    }
    if caption:
        block_content["caption"] = [{"type": "text", "text": {"content": caption}}]

    payload = {
        "children": [
            {
                "type": block_type,
                block_type: block_content,
            }
        ]
    }

    resp = _api_call_with_retry(
        "patch", url, token,
        headers=_headers(token),
        json=payload,
    )
    return _check_response(resp, "Step 3 (attach to page)")


def upload_file_to_notion(
    file_path: str, page_id: str, token: str, caption: str = ""
) -> dict:
    """Upload a local file to a Notion page. Returns upload metadata.

    This is the main entry point — orchestrates the 3-step upload flow.
    The file must be attached within 1 hour of creation (handled atomically here).
    """
    # Validate
    ok, err = validate_file(file_path)
    if not ok:
        raise FileNotFoundError(err) if "not found" in err.lower() else ValueError(err)

    filename = Path(file_path).name
    content_type = detect_content_type(file_path)
    block_type = get_block_type(file_path)
    normalized_page_id = normalize_page_id(page_id)

    # Step 1
    upload_obj = create_file_upload(filename, content_type, token)
    upload_id = upload_obj["id"]

    # Step 2
    send_file_content(upload_id, file_path, token)

    # Step 3
    attach_to_page(normalized_page_id, upload_id, block_type, token, caption)

    return {
        "upload_id": upload_id,
        "filename": filename,
        "content_type": content_type,
        "block_type": block_type,
        "page_id": normalized_page_id,
        "caption": caption,
    }
