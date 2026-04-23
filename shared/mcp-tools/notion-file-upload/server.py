"""MCP server for uploading files to Notion pages.

Uses stdio transport for Claude Code integration.
Requires NOTION_TOKEN environment variable.
"""

import os

from mcp.server import Server
from mcp.server.stdio import stdio_server

from notion_upload import upload_file_to_notion

server = Server("notion-file-upload")


@server.tool()
async def notion_upload_file(file_path: str, page_id: str, caption: str = "") -> str:
    """Upload a local file to a Notion page.

    Supports images (png/jpg/gif/svg/webp), PDFs, and general files
    (docx/xlsx/pptx/txt/csv/zip). Max 20 MB.

    Args:
        file_path: Absolute path to the local file.
        page_id: Notion page ID (with or without dashes).
        caption: Optional caption text for the file block.

    Returns:
        Success or error message.
    """
    token = os.environ.get("NOTION_TOKEN", "")
    if not token:
        return "Error: NOTION_TOKEN environment variable is not set."

    try:
        result = upload_file_to_notion(file_path, page_id, token, caption)
        return (
            f"Uploaded '{result['filename']}' to Notion page {result['page_id']}.\n"
            f"Upload ID: {result['upload_id']}\n"
            f"Block type: {result['block_type']}\n"
            f"Content type: {result['content_type']}"
            + (f"\nCaption: {result['caption']}" if result["caption"] else "")
        )
    except FileNotFoundError as e:
        return f"Error: {e}"
    except ValueError as e:
        return f"Error: {e}"
    except PermissionError as e:
        return f"Error: {e}"
    except RuntimeError as e:
        return f"Error: {e}"
    except Exception as e:
        return f"Error: Unexpected failure — {type(e).__name__}: {e}"


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
