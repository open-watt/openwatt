module urt.mem.scratchpad;

import urt.util;

nothrow @nogc:


enum size_t MaxScratchpadSize = 2048;
enum size_t NumScratchBuffers = 4;

static assert(MaxScratchpadSize.isPowerOf2, "Scratchpad size must be a power of 2");


void[] allocScratchpad(size_t size = MaxScratchpadSize)
{
    if (size > MaxScratchpadSize)
    {
        assert(false, "Size is larger than max scratch page");
        return null;
    }

    size = max(size.nextPowerOf2, WindowSize);
    size_t maskBits = size / WindowSize;
    size_t mask = (1 << maskBits) - 1;

    for (size_t page = 0; page < scratchpadAlloc.length; ++page)
    {
        for (size_t window = 0; window < 8; window += maskBits)
        {
            if ((scratchpadAlloc[page] & (mask << window)) == 0)
            {
                scratchpadAlloc[page] |= mask << window;
                return scratchpad[page*MaxScratchpadSize + window*WindowSize .. page*MaxScratchpadSize + window*WindowSize + size];
            }
        }
    }

    // did not find a free window!
    assert(false, "No scratchpad window available!");
    return null;
}

void freeScratchpad(void[] mem)
{
    size_t page = (cast(size_t)mem.ptr - cast(size_t)scratchpad.ptr) / MaxScratchpadSize;
    size_t window = (cast(size_t)mem.ptr - cast(size_t)scratchpad.ptr) % MaxScratchpadSize / WindowSize;

    size_t maskBits = mem.length / WindowSize;
    size_t mask = (1 << maskBits) - 1;

    assert((scratchpadAlloc[page] & (mask << window)) == (mask << window), "Freeing unallocated scratchpad memory!");
    scratchpadAlloc[page] &= ~(mask << window);
}

private:

enum WindowSize = MaxScratchpadSize / 8;

__gshared ubyte[MaxScratchpadSize*NumScratchBuffers] scratchpad;
__gshared ubyte[NumScratchBuffers] scratchpadAlloc;


unittest
{
    void[] t = allocScratchpad(MaxScratchpadSize);
    assert(t.length == MaxScratchpadSize);
    void[] t2 = allocScratchpad(MaxScratchpadSize / 2);
    assert(t2.length == MaxScratchpadSize / 2);
    void[] t3 = allocScratchpad(MaxScratchpadSize / 2);
    assert(t3.length == MaxScratchpadSize / 2);
    void[] t4 = allocScratchpad(MaxScratchpadSize / 4);
    assert(t4.length == MaxScratchpadSize / 4);
    void[] t5 = allocScratchpad(MaxScratchpadSize / 8);
    assert(t5.length == MaxScratchpadSize / 8);
    void[] t6 = allocScratchpad(MaxScratchpadSize / 4);
    assert(t6.length == MaxScratchpadSize / 4);
    void[] t7 = allocScratchpad(MaxScratchpadSize / 8);
    assert(t7.length == MaxScratchpadSize / 8);

    freeScratchpad(t);
    freeScratchpad(t7);
    freeScratchpad(t5);
    freeScratchpad(t4);
    freeScratchpad(t6);
    freeScratchpad(t2);
    freeScratchpad(t3);
}
