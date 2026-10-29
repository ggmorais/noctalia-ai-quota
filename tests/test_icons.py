from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


class BrandAssetsTests(unittest.TestCase):
    def test_bundled_logos_are_self_contained_svg(self):
        directory = Path(__file__).parents[1] / "ai-quota/icons"
        for name in ("anthropic.svg", "opencode.svg"):
            with self.subTest(icon=name):
                root = ET.parse(directory / name).getroot()
                self.assertEqual(root.tag, "{http://www.w3.org/2000/svg}svg")
                self.assertIn("viewBox", root.attrib)
                self.assertTrue(any(node.tag.endswith("}path") for node in root.iter()))
                for node in root.iter():
                    self.assertNotIn(node.tag.rsplit("}", 1)[-1], ("script", "image", "foreignObject"))
                    for key, value in node.attrib.items():
                        self.assertFalse(key.lower().startswith("on"))
                        if key.endswith("href"):
                            self.assertTrue(value.startswith("#"))


if __name__ == "__main__":
    unittest.main()
