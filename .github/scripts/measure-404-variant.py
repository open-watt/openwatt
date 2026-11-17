from pathlib import Path
import sys

variant = sys.argv[1]
root = Path('third_party/urt/src/urt/mem')
p = root / 'pagepool.d'
t = root / 'pagepool_tiny.d'
s, tiny = p.read_text(), t.read_text()
if variant == 'item1':
    start = s.index('    // a Tiny pool keeps its reserve resident')
    end = s.index('\n\n    alias page_pool_init', start)
    s = s[:start] + '    alias Pool = PagePool!page_classes;' + s[end:]
    start = tiny.index('// the capacity counts the page\'s own cursors; prealloc_pages')
    end = tiny.index('template PagePool(alias classes)', start)
    tiny = tiny[:start] + tiny[end:]
    for idx in ['i', 'category']:
        tiny = tiny.replace(f'classes[{idx}].prealloc_pages', f'classes[{idx}].reserve_pages')
        tiny = tiny.replace(f'classes[{idx}].max_pages', f'(8 * classes[{idx}].pages_per_slab)')
    tiny = tiny.replace("    // the capacity counts the page's own cursors; the pool's words come on top\n", '')
    tiny = tiny.replace('Page.offset.offsetof + ((classes[category].capacity + 7) & ~cast(size_t)7)', '(classes[category].capacity + 7) & ~cast(size_t)7')
    tiny = tiny.replace('private static immutable TinyPageClass[2] test_classes = [TinyPageClass(56, 8, 4), TinyPageClass(248, 4, 0)];', 'private static immutable PageClass[2] test_classes = [PageClass(Page.offset.offsetof + 56, 1, 4), PageClass(Page.offset.offsetof + 248, 1, 0)];')
    tiny = tiny.replace('private static immutable TinyPageClass[1] one_class = [TinyPageClass(248, 4, 1)];', 'private static immutable PageClass[1] one_class = [PageClass(Page.offset.offsetof + 248, 1, 1)];')
    tiny = tiny.replace('private static immutable TinyPageClass[3] three_classes = [TinyPageClass(56, 4, 1), TinyPageClass(120, 4, 1), TinyPageClass(248, 4, 1)];', 'private static immutable PageClass[3] three_classes = [PageClass(Page.offset.offsetof + 56, 1, 1), PageClass(Page.offset.offsetof + 120, 1, 1), PageClass(Page.offset.offsetof + 248, 1, 1)];')
elif variant == 'item2':
    old = '''static foreach (i; 0 .. page_classes.length)
    static assert(page_classes[i].pages_per_slab > 0 && page_classes[i].pages_per_slab <= 256 && page_classes[i].reserve_pages <= 8 * page_classes[i].pages_per_slab, "a page class grows by 1 to 256 pages and reserves no more than eight slabs of them");'''
    new = '''static foreach (i; 0 .. page_classes.length)
{
    static assert(page_classes[i].capacity > Page.sizeof && page_classes[i].capacity <= ushort.max &&
                  (i == 0 || page_classes[i - 1].capacity < page_classes[i].capacity),
                  "page classes are ordered, distinct and each holds a payload within a 16-bit page");
    static assert(page_classes[i].pages_per_slab > 0 && page_classes[i].pages_per_slab <= 256 &&
                  page_classes[i].reserve_pages <= 8 * page_classes[i].pages_per_slab,
                  "a page class grows by 1 to 256 pages and reserves no more than eight slabs of them");
}
version (Tiny) {} else
    static assert(page_classes.length <= max_page_categories);'''
    assert old in s
    s = s.replace(old, new).replace('    import urt.mem.pagepool_tiny;\n', '    import urt.mem.pagepool_tiny;\n\n    static assert(page_classes.length <= page_tag_category_mask);\n')
    s = s.replace('    static assert(page_classes.length <= max_page_categories);\n    static immutable', '    static immutable')
    s = s.replace('defaults[i].page_size > Page.sizeof && defaults[i].page_size <= ushort.max', 'defaults[i].page_size <= ushort.max')
    old = '''    static assert(num_classes > 0 && num_classes <= page_tag_category_mask);
    static foreach (ubyte i; 0 .. num_classes)
        static assert(page_size(i) > Page.sizeof && page_size(i) <= ushort.max && (i == 0 || page_size(i - 1) < page_size(i)) &&
                      classes[i].max_pages > 0 && classes[i].prealloc_pages <= classes[i].max_pages,
                      "page classes round to ordered, distinct pages that each hold a payload");'''
    new = '''    static foreach (ubyte i; 0 .. num_classes)
        static assert(page_size(i) <= ushort.max && (i == 0 || page_size(i - 1) < page_size(i)),
                      "page classes round to distinct pages within 16 bits");'''
    assert old in tiny
    tiny = tiny.replace(old, new)
elif variant == 'combined-loop':
    old = '''        ubyte category = num_classes;
        static foreach (ubyte i; 0 .. num_classes)
        {
            if (required <= page_size(i))
            {
                category = i;
                goto selected;
            }
        }
    selected:'''
    new = '''        ubyte category = 0;
        while (category < num_classes && required > page_size(category))
            ++category;'''
    assert old in tiny
    tiny = tiny.replace(old, new)
else:
    assert variant in ['base404', 'combined-static']
p.write_text(s)
t.write_text(tiny)
