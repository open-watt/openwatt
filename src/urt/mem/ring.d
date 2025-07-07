module urt.mem.ring;

import urt.mem.alloc;
import urt.util;

nothrow @nogc:


enum Options : ubyte
{
    on_overflow_fail = 0,
    on_overflow_drop_old = 1,

    warn_on_overflow = 2,
    // TODO: some options relating to logging on near-full, or debugging stuff?
}


struct RingBuffer(size_t _capacity = 0, Options options = Options.on_overflow_fail)
{
    static assert(_capacity < 2L ^^ 32, "Capacity must be <= 2^^32");

    static if (_capacity == 0)
    {
        void[] buffer;
        size_t capacity() { return buffer.length; }
    }
    else
    {
        void[_capacity] buffer;
        alias capacity = _capacity;
    }

    uint readCur = 0;
    uint writeCur = 0;

    size_t pending()
    {
        if (writeCur >= readCur)
            return writeCur - readCur;
        else
            return capacity - readCur + writeCur;
    }

    size_t available()
    {
        if (writeCur >= readCur)
            return capacity - writeCur + readCur - 1;
        else
            return readCur - writeCur - 1;
    }

    void init(size_t capacity)
    {
        debug assert(_capacity == 0, "Init should only be called for dynamic allocations");
        debug assert(capacity <= uint.max, "Capacity must be < 2^^32");
        buffer = alloc(capacity);
    }

    bool empty()
    {
        return readCur == writeCur;
    }

    void purge()
    {
        readCur = 0;
        writeCur = 0;
    }

    size_t read(void[] buffer)
    {
        return read_ring(buffer, this.buffer[], readCur, writeCur, capacity);
    }

    size_t write(const void[] data)
    {
        return write_ring(buffer[], data, readCur, writeCur, capacity, options);
    }
}


private:

// declare some stuff outside the template...

size_t read_ring(void[] buffer, const void[] data, ref uint readCur, const int writeCur, const size_t capacity)
{
    if (writeCur >= readCur)
    {
        size_t len = min(buffer.length, writeCur - readCur);
        buffer[0 .. len] = data[readCur .. readCur + len];
        readCur += len;
        return len;
    }
    else
    {
        size_t len = min(buffer.length, capacity - readCur);
        buffer[0 .. len] = data[readCur .. readCur + len];
        readCur += len;
        if (readCur == capacity)
        {
            size_t len2 = min(buffer.length - len, writeCur);
            buffer[len .. len + len2] = data[0 .. len2];
            readCur = cast(uint)len2;
            len += len2;
        }
        return len;
    }
}

size_t write_ring(void[] buffer, const void[] data, ref uint readCur, ref uint writeCur, const size_t capacity, Options options)
{
    size_t copy = data.length;
    size_t remain = void;
    if (writeCur >= readCur)
        remain = capacity - writeCur + readCur - 1;
    else
        remain = readCur - writeCur - 1;

    if ((options & 1) == Options.on_overflow_drop_old)
    {
        size_t usable = capacity - 1;
        if (data.length >= usable)
        {
            // too much data! we just keep the tail...
            buffer[0 .. usable] = data[$ - usable .. $];
            readCur = 0;
            writeCur = cast(uint)usable;
            // TODO: if (options & 2) warn about overflow/truncation
            return writeCur;
        }

        if (data.length > remain)
        {
            // shift read-cursor forward to drop old data
            size_t excess = data.length - remain;
            if (readCur + excess < capacity)
                readCur += excess;
            else
                readCur = cast(uint)(excess - (capacity - readCur));
            // TODO: if (options & 2) warn about overflow/truncation
        }
    }
    else
        copy = min(copy, remain);

    size_t tail = capacity - writeCur;
    if (copy >= tail)
    {
        buffer[writeCur .. capacity] = data[0 .. tail];
        writeCur = cast(uint)(copy - tail);
        buffer[0 .. writeCur] = data[tail .. copy];
    }
    else
    {
        buffer[writeCur .. writeCur + copy] = data[0 .. copy];
        writeCur += copy;
    }
    return copy;
}


// unit tests...

unittest
{
    const ubyte[10] t = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    ubyte[64] buffer;

    // test allocated
    RingBuffer!() ring;
    ring.init(256);
    assert(ring.empty);
    assert(ring.pending == 0);
    assert(ring.available == 255);
    assert(ring.write(t[]) == 10);
    assert(!ring.empty);
    assert(ring.pending == 10);
    assert(ring.available == 245);
    assert(ring.read(buffer[]) == 10);
    assert(ring.pending == 0);
    assert(ring.available == 255);
    assert(buffer[0 .. 10] == t[]);
    ring.purge();
    assert(ring.empty);

    // test fixed buffer, with no overwrites
    RingBuffer!(16) ring2;
    assert(ring2.write(t) == 10);
    assert(ring2.write(t) == 5);
    assert(ring2.pending == 15);
    assert(ring2.available == 0);
    assert(ring2.read(buffer[]) == 15);
    assert(buffer[0 .. 10] == t[]);
    assert(buffer[10 .. 15] == t[0 .. 5]);

    // test with overwriting old data
    RingBuffer!(16, Options.on_overflow_drop_old) ring3;
    assert(ring3.write(t) == 10);
    assert(ring3.write(t) == 10);
    assert(ring3.pending == 15);
    assert(ring3.available == 0);
    assert(ring3.read(buffer[]) == 15);
    assert(buffer[0 .. 5] == t[5 .. 10]);
    assert(buffer[5 .. 15] == t[]);

    // this tests some wrapping code paths
    assert(ring3.write(t[0..10]) == 10);
    assert(ring3.write(t[0..10]) == 10);
    assert(ring3.write(t[0..9]) == 9);
    assert(ring3.read(buffer[]) == 15);
    assert(buffer[0 .. 6] == t[4 .. 10]);
    assert(buffer[6 .. 15] == t[0 .. 9]);

    // test overflow of data keeps tail of stream
    RingBuffer!(6, Options.on_overflow_drop_old) ring4;
    assert(ring4.write(t) == 5);
    assert(ring4.pending == 5);
    assert(ring4.available == 0);
    assert(ring4.read(buffer[]) == 5);
    assert(buffer[0 .. 5] == t[5 .. 10]);
}
