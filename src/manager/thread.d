module manager.thread;

import urt.atomic;
import urt.mem.allocator;

import router.iface.packet;

nothrow @nogc:


// thread-safe packet FIFO for passing packets between threads.
// producer enqueues cloned Packet* (ownership transfers to queue).
// consumer dequeues Packet* (ownership transfers to caller, caller must free).
struct ThreadSafePacketQueue(uint _capacity = 64)
{
nothrow @nogc:

    // takes ownership of pkt. drops it if queue is full.
    void enqueue(Packet* pkt)
    {
        while (!cas(&_lock, false, true)) {}
        uint count = _tail >= _head ? _tail - _head : _capacity - _head + _tail;
        if (count < _capacity)
        {
            _queue[_tail] = pkt;
            _tail = (_tail + 1) % _capacity;
        }
        else
            defaultAllocator().free((cast(void*)pkt)[0 .. Packet.sizeof + pkt.length]);
        _lock = false;
    }

    // returns owned Packet* or null. caller must free.
    Packet* dequeue()
    {
        while (!cas(&_lock, false, true)) {}
        if (_head == _tail)
        {
            _lock = false;
            return null;
        }
        auto result = _queue[_head];
        _head = (_head + 1) % _capacity;
        _lock = false;
        return result;
    }

private:
    Packet*[_capacity] _queue;
    shared uint _head;
    shared uint _tail;
    shared bool _lock;
}
