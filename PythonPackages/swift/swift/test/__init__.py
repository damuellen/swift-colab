import unittest
from test import support

class MyTestCase1(unittest.TestCase):

    # Only use setUp() and tearDown() if necessary

    def setUp(self):
        # Nothing

    def tearDown(self):
        # Nothing

    def test_feature_one(self):
        # Test feature one.
        print("hello world testing feature one")

if __name__ == '__main__':
    unittest.main()
