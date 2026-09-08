// Host tool: print the loaded-image footprint of a linked ELF or PE binary.
//
//   binstats <elf|exe> [--image fw.bin] [--partition-table pt.bin]
//                      [--ledger COMPILER --commit HASH --date YYYY-MM-DD]
//
// Reads the section table directly, so it needs no toolchain binutils and gives the same
// numbers on every host. Flash is text+rodata+data (or the packaged image when given), RAM is
// data+bss. Targets linked with the urt RAM-image symbols report their flash limit and the
// init-data image before and after pack_ram_image.py without further flags.
module binstats;

import std.algorithm : all, canFind, filter, map, until;
import std.array : array;
import std.ascii : isDigit;
import std.conv : to;
import std.file : read;
import std.format : format;
import std.getopt;
import std.path : baseName;
import std.stdio : stderr, writefln, writeln;
import std.string : split, strip;

immutable string[] ram_image_symbols = ["_image_start", "_image_limit", "_ram_image_load", "_ram_image_start", "_ram_image_end", "_ram_image_deflated"];

struct Footprint
{
    ulong text, rodata, data, bss;
    ulong[string] symbols;
}

struct Section
{
    string name;
    uint type, link;
    ulong flags, offset, size;
}

int main(string[] args)
{
    string image, partition_table, ledger, commit = "-", date = "-";
    auto opts = getopt(args, "image", &image, "partition-table", &partition_table, "ledger", &ledger, "commit", &commit, "date", &date);
    if (opts.helpWanted || args.length != 2)
    {
        defaultGetoptPrinter("binstats <elf|exe> [options]", opts.options);
        return 1;
    }
    string binary = args[1];

    Footprint fp;
    try
        fp = footprint(cast(ubyte[])read(binary));
    catch (Exception e)
    {
        stderr.writefln("binstats: %s: %s", binary, e.msg);
        return 1;
    }
    ulong flash = fp.text + fp.rodata + fp.data;
    ulong ram = fp.data + fp.bss;
    ulong limit = 0;
    if (partition_table)
        limit = smallest_app_partition(cast(ubyte[])read(partition_table));
    else if ("_image_limit" in fp.symbols)
        limit = fp.symbols["_image_limit"] - fp.symbols["_image_start"];
    ubyte[] img;
    if (image)
    {
        img = cast(ubyte[])read(image);
        flash = img.length;
    }

    writefln("=== %s ===", binary);
    writefln("  text   %10s", commas(fp.text));
    writefln("  rodata %10s", commas(fp.rodata));
    writefln("  data   %10s", commas(fp.data));
    writefln("  bss    %10s", commas(fp.bss));
    if (image && ram_image_symbols.all!(s => (s in fp.symbols) !is null))
    {
        ulong raw = fp.symbols["_ram_image_end"] - fp.symbols["_ram_image_start"];
        ulong offset = fp.symbols["_ram_image_load"] - fp.symbols["_image_start"];
        ulong flag = fp.symbols["_ram_image_deflated"] - fp.symbols["_image_start"];
        ulong packed = img.length - offset;
        string fmt = flag < img.length && img[flag] == 1 ? "deflate" : "raw";
        writefln("  init   %10s -> %s packed (%s), %s saved", commas(raw), commas(packed), fmt, commas(raw - packed));
    }
    if (image)
        writefln("  image  %10s  %s", commas(img.length), baseName(image));
    string line = format("  flash  %10s", commas(flash));
    if (limit)
        line ~= format("  of %s (%d%%), %s free", commas(limit), 100 * flash / limit, commas(limit - flash));
    writeln(line);
    writefln("  ram    %10s", commas(ram));
    if (ledger)
        writefln("  ledger | %s | %s | %s | %s | %s | %s | |", date, commit, compiler_label(ledger), commas(flash), commas(ram), limit ? commas(limit) : "-");
    return 0;
}

Footprint footprint(const(ubyte)[] file)
{
    if (file.length >= 4 && file[0 .. 4] == [0x7F, 'E', 'L', 'F'])
        return elf_footprint(file);
    if (file.length >= 2 && file[0 .. 2] == ['M', 'Z'])
        return pe_footprint(file);
    throw new Exception("not an ELF or PE binary");
}

ulong get(const(ubyte)[] data, size_t at, size_t bytes, bool big = false)
{
    ulong v = 0;
    foreach (i; 0 .. bytes)
        v |= ulong(data[at + i]) << (8 * (big ? bytes - 1 - i : i));
    return v;
}

string cstring(const(ubyte)[] table, size_t at)
{
    return cast(string)table[at .. $].until(0).map!(c => cast(char)c).array;
}

Section[] elf_sections(const(ubyte)[] file, bool is64, bool big)
{
    size_t shoff = cast(size_t)(is64 ? file.get(0x28, 8, big) : file.get(0x20, 4, big));
    size_t hdr = is64 ? 0x3A : 0x2E;
    size_t shentsize = cast(size_t)file.get(hdr, 2, big), shnum = cast(size_t)file.get(hdr + 2, 2, big), shstrndx = cast(size_t)file.get(hdr + 4, 2, big);
    Section[] sections;
    uint[] name_offsets;
    foreach (i; 0 .. shnum)
    {
        size_t s = shoff + i * shentsize;
        Section sec;
        sec.type = cast(uint)file.get(s + 4, 4, big);
        if (is64)
        {
            sec.flags = file.get(s + 8, 8, big);
            sec.offset = file.get(s + 24, 8, big);
            sec.size = file.get(s + 32, 8, big);
            sec.link = cast(uint)file.get(s + 40, 4, big);
        }
        else
        {
            sec.flags = file.get(s + 8, 4, big);
            sec.offset = file.get(s + 16, 4, big);
            sec.size = file.get(s + 20, 4, big);
            sec.link = cast(uint)file.get(s + 24, 4, big);
        }
        sections ~= sec;
        name_offsets ~= cast(uint)file.get(s, 4, big);
    }
    const(ubyte)[] strtab = contents(file, sections[shstrndx]);
    foreach (i, ref sec; sections)
        sec.name = cstring(strtab, name_offsets[i]);
    return sections;
}

const(ubyte)[] contents(const(ubyte)[] file, ref const Section sec)
{
    return file[cast(size_t)sec.offset .. cast(size_t)(sec.offset + sec.size)];
}

Footprint elf_footprint(const(ubyte)[] file)
{
    bool is64 = file[4] == 2, big = file[5] == 2;
    Section[] sections = elf_sections(file, is64, big);
    Footprint fp;
    foreach (ref sec; sections.filter!(s => (s.flags & 2) && !s.name.canFind("dummy")))
    {
        if (sec.type == 8)
            fp.bss += sec.size;
        else if (sec.flags & 4)
            fp.text += sec.size;
        else if ((sec.flags & 1) && !sec.name.canFind("rodata"))
            fp.data += sec.size;
        else
            fp.rodata += sec.size;
    }
    foreach (ref symtab; sections.filter!(s => s.type == 2))
    {
        const(ubyte)[] names = contents(file, sections[symtab.link]);
        const(ubyte)[] syms = contents(file, symtab);
        size_t entsize = is64 ? 24 : 16;
        for (size_t off = 0; off + entsize <= syms.length; off += entsize)
        {
            string name = cstring(names, cast(size_t)syms.get(off, 4, big));
            if (ram_image_symbols.canFind(name))
                fp.symbols[name] = is64 ? syms.get(off + 8, 8, big) : syms.get(off + 4, 4, big);
        }
    }
    return fp;
}

Footprint pe_footprint(const(ubyte)[] file)
{
    size_t pe = cast(size_t)file.get(0x3C, 4);
    size_t nsect = cast(size_t)file.get(pe + 6, 2);
    size_t opt = cast(size_t)file.get(pe + 20, 2);
    size_t s = pe + 24 + opt;
    Footprint fp;
    foreach (i; 0 .. nsect)
    {
        ulong vsize = file.get(s + 8, 4), rawsize = file.get(s + 16, 4), flags = file.get(s + 36, 4);
        s += 40;
        if (flags & 0x02000000)
            continue;
        if (flags & 0x80)
            fp.bss += vsize;
        else if (flags & 0x20000000)
            fp.text += vsize;
        else if (flags & 0x80000000)
        {
            fp.data += rawsize;
            fp.bss += vsize > rawsize ? vsize - rawsize : 0;
        }
        else
            fp.rodata += vsize;
    }
    return fp;
}

ulong smallest_app_partition(const(ubyte)[] table)
{
    ulong smallest = 0;
    for (size_t off = 0; off + 32 <= table.length && table[off .. off + 2] == [0xAA, 0x50]; off += 32)
    {
        ulong size = table.get(off + 8, 4);
        if (table[off + 2] == 0 && (smallest == 0 || size < smallest))
            smallest = size;
    }
    return smallest;
}

string compiler_label(string raw)
{
    string name = raw.canFind("LDC") ? "ldc" : raw.canFind("gdc", "GDC") ? "gdc" : "dmd";
    foreach (word; raw.split)
    {
        string v = word.strip("(v", "),:");
        if (v.length && v[0].isDigit)
            return name ~ " " ~ v;
    }
    return name;
}

string commas(ulong v)
{
    string s = v.to!string;
    string r;
    foreach (i, c; s)
    {
        if (i && (s.length - i) % 3 == 0)
            r ~= ',';
        r ~= c;
    }
    return r;
}
