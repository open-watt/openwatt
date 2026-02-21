module router.iface.priority_queue;

import urt.array;
import urt.mem.allocator;
import urt.mem.freelist;
import urt.time;

import router.iface : MessageCallback, MessageState;
import router.iface.packet;
import router.status : Status;

nothrow @nogc:


struct QueuedFrame
{
    Packet* packet;
    MessageCallback callback;
    MonoTime enqueue_time;
    MonoTime dispatch_time;
    ubyte tag;
    PCP pcp;
    bool dei;
    bool in_flight;
}

struct PriorityPacketQueue
{
nothrow @nogc:

    void init(Duration timeout, ubyte max_in_flight, ubyte reserved_slots = 0, PCP reserved_min_pcp = PCP.vo, Status* status = null)
    {
        assert(max_in_flight > 0, "max_in_flight must be greater than 0");
        assert(reserved_slots < max_in_flight, "Reserved slots cannot exceed total capacity");

        _max_in_flight = max_in_flight;
        _timeout = timeout;
        _status = status;
        _reserved_slots = reserved_slots;
        _reserved_min_rank = pcp_priority_map[reserved_min_pcp];
    }

    size_t queue_depth(PCP pcp) const pure
        => _buckets[pcp_priority_map[pcp]].length;

    size_t in_flight_count() const pure
        => _in_flight_count;

    bool has_pending() const pure
        => _queued_count > 0;

    bool has_capacity(PCP pcp = PCP.nc) const pure
    {
        ubyte rank = pcp_priority_map[pcp];
        uint limit = rank >= _reserved_min_rank ? _max_in_flight : _max_in_flight - _reserved_slots;
        return _in_flight_count < limit;
    }

    bool is_queued(ubyte tag) const pure
    {
        foreach (ref bucket; _buckets)
        {
            foreach (frame; bucket[])
            {
                if (frame.tag == tag)
                    return true;
            }
        }
        return false;
    }

    int enqueue(ref Packet packet, MessageCallback callback = null)
    {
        PCP pcp = packet.pcp;
        bool dei = packet.dei;

        // check total queue capacity
        if (_queued_count >= _max_queue_depth)
        {
            // try to drop a DEI=1 frame if this frame is DEI=0
            if (!dei && !drop_lowest_dei())
                return -1;
            else if (dei)
                return -1; // drop the new DEI=1 frame
        }

        QueuedFrame* frame = _pool.alloc();
        frame.packet = packet.clone();
        frame.callback = callback;
        frame.enqueue_time = getTime();
        frame.tag = next_tag();
        frame.pcp = pcp;
        frame.dei = dei;
        frame.in_flight = false;

        ubyte rank = pcp_priority_map[pcp];
        _buckets[rank].pushBack(frame);
        ++_queued_count;

        return frame.tag;
    }

    QueuedFrame* dequeue()
    {
        for (int rank = 7; rank >= 0; --rank)
        {
            if (_buckets[rank].length == 0)
                continue;

            uint limit = rank >= _reserved_min_rank ? _max_in_flight : _max_in_flight - _reserved_slots;
            if (_in_flight_count >= limit)
                continue;

            QueuedFrame* frame = _buckets[rank][0];
            _buckets[rank].remove(0);
            --_queued_count;
            frame.dispatch_time = getTime();
            frame.in_flight = true;
            _in_flight.pushBack(frame);
            ++_in_flight_count;
            return frame;
        }
        return null;
    }

    void complete(ubyte tag, MessageState state = MessageState.complete, MonoTime timestamp = getTime())
    {
        foreach (i, frame; _in_flight[])
        {
            if (frame.tag == tag)
            {
                update_time_stats(frame, timestamp);
                if (frame.callback)
                    frame.callback(tag, state);
                free_frame(frame);
                _in_flight.remove(i);
                --_in_flight_count;
                return;
            }
        }
    }

    bool abort(ubyte tag, MessageState reason = MessageState.aborted)
    {
        foreach (i, frame; _in_flight[])
        {
            if (frame.tag == tag)
            {
                if (frame.callback)
                    frame.callback(tag, reason);
                free_frame(frame);
                _in_flight.remove(i);
                --_in_flight_count;
                return true;
            }
        }
        foreach (ref bucket; _buckets)
        {
            foreach (i, frame; bucket[])
            {
                if (frame.tag == tag)
                {
                    if (frame.callback)
                        frame.callback(tag, reason);
                    free_frame(frame);
                    bucket.remove(i);
                    --_queued_count;
                    return true;
                }
            }
        }
        return false;
    }

    void abort_all(MessageState reason = MessageState.aborted)
    {
        foreach (ref bucket; _buckets)
        {
            foreach (frame; bucket[])
            {
                if (frame.callback)
                    frame.callback(frame.tag, reason);
                free_frame(frame);
            }
            bucket.clear();
        }
        _queued_count = 0;

        foreach (frame; _in_flight[])
        {
            if (frame.callback)
                frame.callback(frame.tag, reason);
            free_frame(frame);
        }
        _in_flight.clear();
        _in_flight_count = 0;
    }

    void abort_all_in_flight(MessageState reason = MessageState.aborted)
    {
        foreach (frame; _in_flight[])
        {
            if (frame.callback)
                frame.callback(frame.tag, reason);
            free_frame(frame);
        }
        _in_flight.clear();
        _in_flight_count = 0;
    }

    void timeout_stale(MonoTime now)
    {
        size_t i = 0;
        while (i < _in_flight.length)
        {
            QueuedFrame* frame = _in_flight[i];
            if ((now - frame.enqueue_time) > _timeout)
            {
                if (frame.callback)
                    frame.callback(frame.tag, MessageState.timeout);
                free_frame(frame);
                _in_flight.remove(i);
                --_in_flight_count;
            }
            else
                ++i;
        }
    }

private:

    enum _max_queue_depth = 32;

    // buckets indexed by rank (0=lowest priority, 7=highest), NOT by PCP value
    Array!(QueuedFrame*)[8] _buckets;
    Array!(QueuedFrame*) _in_flight;
    FreeList!QueuedFrame _pool;

    Status* _status;

    ubyte _max_in_flight;
    ubyte _in_flight_count;
    ubyte _queued_count;
    ubyte _next_tag;
    ubyte _reserved_slots;
    ubyte _reserved_min_rank;
    Duration _timeout;

    void update_time_stats(QueuedFrame* frame, MonoTime timestamp)
    {
        if (!_status)
            return;

        uint wait_us = cast(uint)(frame.dispatch_time - frame.enqueue_time).as!"usecs";
        uint service_us = cast(uint)(timestamp - frame.dispatch_time).as!"usecs";

        // EWMA: 7/8 * old + 1/8 * new
        _status.avg_queue_us = (_status.avg_queue_us*7 + wait_us) / 8;
        _status.avg_service_us = (_status.avg_service_us*7 + service_us) / 8;

        if (service_us > _status.max_service_us)
            _status.max_service_us = service_us;
    }

    ubyte next_tag() pure
    {
        ubyte tag = _next_tag++;
        if (_next_tag == 0)
            _next_tag = 1;
        return tag;
    }

    bool drop_lowest_dei()
    {
        for (int rank = 0; rank <= 7; ++rank)
        {
            // TODO: should we scan backwards within bucket? choose newest or oldest?
            //       do we prefer freshest data, or the guy who's been waiting longest?
            foreach_reverse (i, frame; _buckets[rank][])
            {
                if (frame.dei)
                {
                    if (frame.callback)
                        frame.callback(frame.tag, MessageState.dropped);
                    free_frame(frame);
                    _buckets[rank].remove(i);
                    --_queued_count;
                    return true;
                }
            }
        }
        return false;
    }

    void free_frame(QueuedFrame* frame)
    {
        if (frame.packet)
        {
            size_t alloc_size = Packet.sizeof + frame.packet.length;
            defaultAllocator().free((cast(void*)frame.packet)[0 .. alloc_size]);
            frame.packet = null;
        }
        frame.callback = null;
        _pool.free(frame);
    }
}
