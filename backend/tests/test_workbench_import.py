import importlib.util
import sys
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1] / "cortex_sentinel/workbench"
sys.path.insert(0, str(ROOT))
from import_html import parse_map


class ImportTests(unittest.TestCase):
    def test_keeps_visual_semantics_and_free_research(self):
        html = '''<h2>自由研究</h2><p>保留不适合卡片的长内容</p><script>
        const GROUPS=[{name:'连接',ids:['A']}];
        const B={A:{n:'模块',c:'orange',u:'正文',f:['发现'],w:'待用户选择'}};
        const chipText={orange:'还没有覆盖，绝非失败'};
        const EXT=['尚未开工的模块'];</script>'''
        data = parse_map(html, "new-module", "map.html", "2026-09-21T00:00:00Z")
        self.assertEqual(data["blocks"][0]["source_color"], "orange")
        self.assertEqual(data["blocks"][0]["source_label"], "还没有覆盖，绝非失败")
        self.assertIn("长内容", data["sections"][0]["body"])
        self.assertEqual(data["external"], ["尚未开工的模块"])

    def test_does_not_evaluate_html_scripts(self):
        text = "const GROUPS=[{name:'x',ids:['A']}];const B={A:dangerous()};"
        with self.assertRaises(ValueError):
            parse_map(text, "new-module", "map.html", "2026-09-21T00:00:00Z")

    def test_rejects_duplicate_blocks(self):
        text = "const GROUPS=[{name:'x',ids:['A','A']}];const B={A:{n:'a'}};"
        with self.assertRaises(ValueError):
            parse_map(text, "new-module", "map.html", "2026-09-21T00:00:00Z")

if __name__ == '__main__':
    unittest.main()
