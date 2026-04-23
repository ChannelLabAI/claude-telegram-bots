# Notion File Upload MCP Tool

Upload local files (PDF, images, documents) to Notion pages via the Notion File Upload API (version 2026-03-11). Designed for Claude Code bot integrations — receives files from Telegram and attaches them to Notion.

## Prerequisites

- Python 3.10+
- A Notion integration token with page write access

## Installation

```bash
cd ~/.claude-bots/shared/mcp-tools/notion-file-upload
pip install -r requirements.txt
```

## Configuration

Set the `NOTION_TOKEN` environment variable:

```bash
export NOTION_TOKEN=ntn_your_token_here
```

The token must belong to a Notion integration that has been connected to the target workspace and pages.

### Token sources

The team's Notion MCP integration is managed via Claude's built-in MCP connection. For this standalone tool, provide the token as an environment variable in the MCP server configuration (see below).

## MCP Server Registration

Add to `~/.claude/settings.json` under `mcpServers`:

```json
{
  "mcpServers": {
    "notion-file-upload": {
      "command": "python3",
      "args": ["/home/oldrabbit/.claude-bots/shared/mcp-tools/notion-file-upload/server.py"],
      "env": {
        "NOTION_TOKEN": "ntn_your_token_here"
      }
    }
  }
}
```

## Usage Examples

### Upload a PDF

```
notion_upload_file(
  file_path="/tmp/report.pdf",
  page_id="12345678-abcd-1234-efgh-123456789abc"
)
```

### Upload an image with caption

```
notion_upload_file(
  file_path="/tmp/screenshot.png",
  page_id="12345678abcd1234efgh123456789abc",
  caption="Dashboard screenshot — 2026-04-07"
)
```

## Supported File Types

| Extension | MIME Type | Notion Block |
|-----------|-----------|-------------|
| .png | image/png | image |
| .jpg/.jpeg | image/jpeg | image |
| .gif | image/gif | image |
| .svg | image/svg+xml | image |
| .webp | image/webp | image |
| .pdf | application/pdf | pdf |
| .docx | application/vnd...wordprocessingml | file |
| .xlsx | application/vnd...spreadsheetml | file |
| .pptx | application/vnd...presentationml | file |
| .txt | text/plain | file |
| .csv | text/csv | file |
| .zip | application/zip | file |

Unrecognized extensions default to `application/octet-stream` with `file` block type.

## Error Handling

- **File not found** — immediate error, no API call
- **File > 20 MB** — immediate error with size shown
- **Empty file** — immediate error
- **401/403** — "Notion token invalid or missing permissions"
- **429 rate limit** — automatic retry once after 1 second
- **Other API errors** — HTTP status + response body

## API Notes

- Uses Notion API version `2026-03-11` (File Upload API)
- The 3-step flow (create → send → attach) runs atomically — the 1-hour upload expiry window is not a concern
- File size limit: 20 MB (Notion's limit)
- Page ID accepts both dashed and undashed UUID formats

## Testing

```bash
cd ~/.claude-bots/shared/mcp-tools/notion-file-upload
python3 -m pytest test_upload.py -v
# or
python3 test_upload.py
```
