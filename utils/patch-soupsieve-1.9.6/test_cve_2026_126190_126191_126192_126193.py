import re
import unittest

from bs4 import BeautifulSoup
import soupsieve
from soupsieve import css_match, css_parser


class SoupSieveSecurityTests(unittest.TestCase):
    def test_descendant_cache_reuses_shared_ancestry(self):
        soup = BeautifulSoup('<main><section><h1></h1><p></p></section></main>', 'html.parser')
        compiled = soupsieve.compile('main section *')
        matcher = css_match.CSSMatch(compiled.selectors, soup.section,
                                     compiled.namespaces, compiled.flags)
        visited = []
        get_parent = matcher.get_parent

        def count_parent(tag, no_iframe=False):
            visited.append(tag.name)
            return get_parent(tag, no_iframe)

        matcher.get_parent = count_parent
        self.assertTrue(matcher.match(soup.h1))
        self.assertEqual(visited, ['h1', 'section'])
        del visited[:]
        self.assertTrue(matcher.match(soup.p))
        self.assertEqual(visited, ['p'])

    def test_general_and_adjacent_siblings_inside_has(self):
        soup = BeautifulSoup(
            '<section id="one"><i></i><span></span><i></i><b></b></section>'
            '<section id="two"><b></b><i></i></section>', 'html.parser')
        for combinator in ('~', '+'):
            matches = soupsieve.select('section:has(i %s b)' % combinator, soup)
            self.assertEqual([tag['id'] for tag in matches], ['one'])
        self.assertEqual(soupsieve.select('section:has(span + b)', soup), [])

    def test_general_sibling_cache_reuses_suffix(self):
        soup = BeautifulSoup('<section><i></i><i></i><i></i></section>', 'html.parser')
        compiled = soupsieve.compile('section:has(i ~ b)')
        matcher = css_match.CSSMatch(compiled.selectors, soup.section,
                                     compiled.namespaces, compiled.flags)
        traversed = []
        get_next = matcher.get_next

        def count_next(tag):
            traversed.append(tag)
            return get_next(tag)

        matcher.get_next = count_next
        self.assertFalse(matcher.match(soup.section))
        self.assertEqual(len(traversed), 3)

    def test_hex_escape_and_literal_escape_semantics(self):
        soup = BeautifulSoup('<p id="123" data-1="a-b"></p>', 'html.parser')
        for selector in (r'#\31 23', r'#\00003123', r'[data-\31 =a\-b]'):
            self.assertIs(soupsieve.select_one(selector, soup), soup.p)

    def test_hex_escape_cannot_backtrack_to_shorter_escape(self):
        pattern = re.compile(css_parser.CSS_ESCAPES + r'1$', re.IGNORECASE)
        self.assertIsNone(pattern.match(r'\31'))
        self.assertIsNotNone(pattern.match(r'\0000311'))

    def test_selector_depth_limit(self):
        limit = css_parser._MAX_SELECTOR_DEPTH
        self.assertIsNotNone(soupsieve.compile(':is(' * (limit - 1) + 'p' + ')' * (limit - 1)))
        self.assertRaisesRegexp(soupsieve.SelectorSyntaxError, 'Selector nesting exceeds limit',
                                soupsieve.compile, ':is(' * limit + 'p' + ')' * limit)

    def test_iterator_observes_changed_ancestor(self):
        soup = BeautifulSoup('<main><p id="one"></p><p id="two"></p></main>', 'html.parser')
        matches = soupsieve.iselect('main p', soup)
        self.assertEqual(next(matches)['id'], 'one')
        soup.main.name = 'aside'
        self.assertEqual(list(matches), [])


if __name__ == '__main__':
    unittest.main()
