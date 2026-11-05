import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from goodwe_apk_inventory import factory_cases, literal_bytes


class InventoryTests(unittest.TestCase):
    def test_factory_with_head_before_command_id(self):
        source = '''    public static byte[] build(String head, int type) {
        switch (type) {
        case 3:
            return wrap(new byte[]{90,90,1,3,0,0});
        }
    }
'''
        self.assertEqual(["5a5a01030000"], factory_cases(source, "build")[0]["literal_byte_arrays"])

    def test_literals_are_resolved_without_evaluation(self):
        self.assertEqual("aa55001a", literal_bytes("-86, 85, 0, Ascii.SUB"))
        self.assertIsNone(literal_bytes("-86, dynamicValue"))
        self.assertIsNone(literal_bytes("256"))

    def test_cases_do_not_inherit_nested_default_or_next_method(self):
        source = '''    public static byte[] build(int type) {
        switch (type) {
        case READ /* 5 */:
            return wrap(new byte[]{-86, 85, Ascii.SUB});
        default:
            switch (type) {
            case RESET /* 6 */:
                return wrap(new byte[]{3, 99});
            }
        }
    }
    public static byte[] other(int type) {
        switch(type) { case 7: return null; }
    }
'''
        rows = factory_cases(source, "build")
        self.assertEqual(["READ", "RESET"], [row["case"] for row in rows])
        self.assertEqual(["aa551a"], rows[0]["literal_byte_arrays"])
        self.assertEqual(["0363"], rows[1]["literal_byte_arrays"])


if __name__ == "__main__":
    unittest.main()
