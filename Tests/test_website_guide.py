"""Verify checked-in product guides and the Pandoc publication path."""
from html.parser import HTMLParser
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).resolve().parents[1]


class Links(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.targets = []
        self.ids = []
        self.text = []
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "a":
            self.targets.append(attributes["href"])
        if "id" in attributes:
            self.ids.append(attributes["id"])

    def handle_data(self, data):
        if data.strip():
            self.text.append(data.strip())


class WebsiteGuideTests(unittest.TestCase):
    def test_landing_and_language_switch_reach_guides_with_working_navigation(self):
        for path, alternate in [("voice", "ru/voice"), ("ru/voice", "voice")]:
            with self.subTest(path=path):
                landing = ROOT / "website/dist" / path
                self.assertIn(f"/{path}/docs/", Links((landing / "index.html").read_text()).targets)
                guide = Links((landing / "docs/index.html").read_text())
                self.assertIn(f"/{alternate}/docs/", guide.targets)
                self.assertIn("https://github.com/Pichi-AI/pichi-voice/blob/main/SUPPORT.md", guide.targets)
                anchors = [href[1:] for href in guide.targets if href.startswith("#")]
                self.assertGreater(len(anchors), 1)
                self.assertTrue(set(anchors).issubset(guide.ids))
                self.assertEqual(len(set(guide.ids)), len(guide.ids))

    @unittest.skipUnless(shutil.which("pandoc"), "Regenerating the website requires Pandoc")
    def test_renderer_preserves_both_sources_and_new_markdown_content(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "website/guide", root / "website/guide")
            product = root / "docs/product"
            product.mkdir(parents=True)
            for filename in ["user-guide.md", "user-guide.ru.md"]:
                shutil.copy(ROOT / "docs/product" / filename, product)
            def render():
                subprocess.run(["sh", "website/guide/render.sh"], cwd=root, check=True)
            render()
            for subdir in ["voice", "ru/voice"]:
                route = Path("website/dist") / subdir / "docs/index.html"
                published = Links((ROOT / route).read_text())
                built = Links((root / route).read_text())
                self.assertEqual((built.text, built.targets, built.ids),
                                 (published.text, published.targets, published.ids))

            with (product / "user-guide.ru.md").open("a") as guide:
                guide.write("\n## Проверка\n\nПункт с **выделением** и [ссылкой](privacy.md).\n")
            render()
            ru = Links((root / "website/dist/ru/voice/docs/index.html").read_text())
            self.assertIn("#проверка", ru.targets)
            self.assertIn("выделением", ru.text)
            self.assertIn("https://github.com/Pichi-AI/pichi-voice/blob/main/docs/product/privacy.md", ru.targets)


if __name__ == "__main__":
    unittest.main()
