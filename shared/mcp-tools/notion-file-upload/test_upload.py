"""Unit tests for notion_upload.py — no real API calls."""

import os
import tempfile
import unittest

from notion_upload import (
    detect_content_type,
    get_block_type,
    normalize_page_id,
    validate_file,
    MAX_FILE_SIZE,
)


class TestDetectContentType(unittest.TestCase):
    """Test MIME type detection for all supported extensions."""

    def test_pdf(self):
        self.assertEqual(detect_content_type("doc.pdf"), "application/pdf")

    def test_png(self):
        self.assertEqual(detect_content_type("img.png"), "image/png")

    def test_jpg(self):
        self.assertEqual(detect_content_type("photo.jpg"), "image/jpeg")

    def test_jpeg(self):
        self.assertEqual(detect_content_type("photo.jpeg"), "image/jpeg")

    def test_gif(self):
        self.assertEqual(detect_content_type("anim.gif"), "image/gif")

    def test_svg(self):
        self.assertEqual(detect_content_type("icon.svg"), "image/svg+xml")

    def test_webp(self):
        self.assertEqual(detect_content_type("photo.webp"), "image/webp")

    def test_docx(self):
        ct = detect_content_type("report.docx")
        self.assertIn("wordprocessingml", ct)

    def test_xlsx(self):
        ct = detect_content_type("data.xlsx")
        self.assertIn("spreadsheetml", ct)

    def test_pptx(self):
        ct = detect_content_type("slides.pptx")
        self.assertIn("presentationml", ct)

    def test_txt(self):
        self.assertEqual(detect_content_type("notes.txt"), "text/plain")

    def test_csv(self):
        self.assertEqual(detect_content_type("data.csv"), "text/csv")

    def test_zip(self):
        self.assertEqual(detect_content_type("archive.zip"), "application/zip")

    def test_unknown_extension(self):
        self.assertEqual(detect_content_type("file.xyz123"), "application/octet-stream")

    def test_case_insensitive_via_path(self):
        # Path.suffix preserves case, but our lookup lowercases
        self.assertEqual(detect_content_type("IMG.PNG"), "image/png")


class TestGetBlockType(unittest.TestCase):
    """Test block type selection logic."""

    def test_images(self):
        for ext in ["png", "jpg", "jpeg", "gif", "svg", "webp"]:
            self.assertEqual(get_block_type(f"file.{ext}"), "image", f"Failed for .{ext}")

    def test_pdf(self):
        self.assertEqual(get_block_type("doc.pdf"), "pdf")

    def test_docx(self):
        self.assertEqual(get_block_type("doc.docx"), "file")

    def test_xlsx(self):
        self.assertEqual(get_block_type("data.xlsx"), "file")

    def test_txt(self):
        self.assertEqual(get_block_type("notes.txt"), "file")

    def test_zip(self):
        self.assertEqual(get_block_type("archive.zip"), "file")

    def test_unknown(self):
        self.assertEqual(get_block_type("thing.foo"), "file")


class TestNormalizePageId(unittest.TestCase):
    """Test page ID normalization."""

    def test_with_dashes(self):
        self.assertEqual(
            normalize_page_id("12345678-1234-1234-1234-123456789abc"),
            "12345678123412341234123456789abc",
        )

    def test_dashes_removed(self):
        result = normalize_page_id("abcd-ef01-2345")
        self.assertNotIn("-", result)
        self.assertEqual(result, "abcdef012345")

    def test_without_dashes(self):
        raw = "abcdef0123456789abcdef0123456789"
        self.assertEqual(normalize_page_id(raw), raw)

    def test_mixed(self):
        self.assertEqual(normalize_page_id("a-b-c"), "abc")


class TestValidateFile(unittest.TestCase):
    """Test file validation logic."""

    def test_nonexistent_file(self):
        ok, msg = validate_file("/nonexistent/path/file.pdf")
        self.assertFalse(ok)
        self.assertIn("not found", msg.lower())

    def test_directory_not_file(self):
        ok, msg = validate_file("/tmp")
        self.assertFalse(ok)
        self.assertIn("Not a file", msg)

    def test_valid_small_file(self):
        with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
            f.write(b"hello")
            f.flush()
            ok, msg = validate_file(f.name)
            self.assertTrue(ok)
            self.assertEqual(msg, "")
            os.unlink(f.name)

    def test_empty_file(self):
        with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
            # write nothing
            f.flush()
            ok, msg = validate_file(f.name)
            self.assertFalse(ok)
            self.assertIn("empty", msg.lower())
            os.unlink(f.name)

    def test_oversize_file(self):
        # Create a sparse file that appears > 20 MB
        with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
            f.seek(MAX_FILE_SIZE + 1)
            f.write(b"\0")
            f.flush()
            ok, msg = validate_file(f.name)
            self.assertFalse(ok)
            self.assertIn("too large", msg.lower())
            self.assertIn("MB", msg)
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
