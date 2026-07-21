module router.iface.priority_queue;

import urt.array;
import urt.mem.allocator;
import urt.mem.freelist;
import urt.time;

import router.iface : BaseInterface, MessageCallback, MessageState, TagAllocator;
import router.iface.packet;

nothrow @nogc:


struct QueuedFrame
{
    Packet* packet;
    MessageCallback callback;
    MonoTime enqueue_time;
    MonoTime dispatch_time;
    uint deadline_after;
    uint priority_escalation_after;
    ubyte tag;
    PCP pcp;
    PCP urgent_pcp;
    bool dei;
    bool in_flight;
    bool priority_escalated;
}

struct PriorityPacketQueue
{
nothrow @nogc:

    void init(ubyte max_in_flight, ubyte reserved_slots = 0, PCP reserved_min_pcp = PCP.vo, BaseInterface iface = null)
    {
        set_capacity(max_in_flight, reserved_slots, reserved_min_pcp);
        _if = iface;
    }

    void set_capacity(ubyte max_in_flight, ubyte reserved_slots = 0, PCP reserved_min_pcp = PCP.vo)
    {
        assert(max_in_flight > 0, "max_in_flight must be greater than 0");
        assert(reserved_slots < max_in_flight, "Reserved slots cannot exceed total capacity");

        _max_in_flight = max_in_flight;
        _reserved_slots = reserved_slots;
        _reserved_min_rank = pcp_priority_map[reserved_min_pcp];
    }

    // Duration(0) = no expiry (frames wait indefinitely for a slot)
    void set_queue_timeout(Duration timeout)
    {
        _queue_timeout = timeout;
    }

    // evict in-flight frames after this duration
    // Duration(0) = never evict frames
    void set_transport_timeout(Duration timeout)
    {
        _transport_timeout = timeout;
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

    const(QueuedFrame)* find_in_flight(ubyte tag) const pure
    {
        foreach (frame; _in_flight[])
        {
            if (frame.tag == tag)
                return frame;
        }
        return null;
    }

    int enqueue(ref Packet packet, MessageCallback callback = null, const(QueuePolicy)* policy = null)
    {
        PCP pcp = packet.pcp;
        bool dei = packet.dei;

        // check total queue capacity
        if (_queued_count >= _max_queue_depth)
        {
            if (!dei && !drop_lowest_dei())
                return -1;
            else if (dei)
                return -1;
        }

        QueuedFrame* frame = _pool.alloc();
        frame.packet = packet.clone();
        frame.callback = callback;
        frame.enqueue_time = getTime();
        frame.deadline_after = policy ? policy.deadline_after : 0;
        frame.priority_escalation_after = policy ? policy.priority_escalation_after : 0;
        int tag = _tags.alloc();
        if (tag < 0)
        {
            frame.packet.free_clone();
            _pool.free(frame);
            return -1;
        }
        frame.tag = cast(ubyte)tag;
        frame.pcp = pcp;
        frame.urgent_pcp = policy ? policy.urgent_pcp : PCP.be;
        frame.dei = dei;
        frame.in_flight = false;
        frame.priority_escalated = false;

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
        promote_due(now);

        foreach (ref bucket; _buckets)
        {
            size_t i = 0;
            while (i < bucket.length)
            {
                QueuedFrame* frame = bucket[i];
                if ((frame.deadline_after != 0 && packet_age_ms(frame, now) >= frame.deadline_after) ||
                    (_queue_timeout != Duration() && (now - frame.enqueue_time) > _queue_timeout))
                {
                    if (frame.callback)
                        frame.callback(frame.tag, MessageState.expired);
                    free_frame(frame);
                    bucket.remove(i);
                    --_queued_count;
                }
                else
                    ++i;
            }
        }

        if (_transport_timeout != Duration())
        {
            size_t i = 0;
            while (i < _in_flight.length)
            {
                QueuedFrame* frame = _in_flight[i];
                if ((now - frame.dispatch_time) > _transport_timeout)
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
    }

private:

    enum _max_queue_depth = 32;

    // buckets indexed by rank (0=lowest priority, 7=highest), NOT by PCP value
    Array!(QueuedFrame*)[8] _buckets;
    Array!(QueuedFrame*) _in_flight;
    FreeList!QueuedFrame _pool;

    BaseInterface _if;

    ubyte _max_in_flight;
    ubyte _in_flight_count;
    ubyte _queued_count;
    ubyte _reserved_slots;
    ubyte _reserved_min_rank;
    ubyte _next_tag;

    TagAllocator _tags;

    Duration _queue_timeout;
    Duration _transport_timeout;

    void update_time_stats(QueuedFrame* frame, MonoTime timestamp)
    {
        if (!_if)
            return;

        uint wait_us = cast(uint)(frame.dispatch_time - frame.enqueue_time).as!"usecs";
        uint service_us = cast(uint)(timestamp - frame.dispatch_time).as!"usecs";

        _if.queue_update_service_times(wait_us, service_us);
    }

    void promote_due(MonoTime now)
    {
        for (int rank = 0; rank <= 7; ++rank)
        {
            size_t i = 0;
            while (i < _buckets[rank].length)
            {
                QueuedFrame* frame = _buckets[rank][i];
                ubyte urgent_rank = pcp_priority_map[frame.urgent_pcp];
                if (frame.deadline_after != 0 && !frame.priority_escalated &&
                    packet_age_ms(frame, now) >= frame.priority_escalation_after && urgent_rank > rank)
                {
                    _buckets[rank].remove(i);
                    frame.priority_escalated = true;
                    frame.pcp = frame.urgent_pcp;
                    _buckets[urgent_rank].pushBack(frame);
                }
                else
                    ++i;
            }
        }
    }

    long packet_age_ms(const QueuedFrame* frame, MonoTime now) pure
        => (now - frame.packet.creation_time).as!"msecs";

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
        _tags.free(frame.tag);
        if (frame.packet)
        {
            frame.packet.free_clone();
            frame.packet = null;
        }
        frame.callback = null;
        _pool.free(frame);
    }
}

unittest
{
    ubyte[1] data;
    Packet low;
    low.init!RawFrame(data[]);
    low.pcp = PCP.be;

    Packet urgent;
    urgent.init!RawFrame(data[]);
    urgent.pcp = PCP.vo;

    PriorityPacketQueue queue;
    queue.init(3, 1, PCP.vo);

    assert(queue.enqueue(low) >= 0);
    assert(queue.enqueue(low) >= 0);
    assert(queue.dequeue() !is null);
    assert(queue.dequeue() !is null);

    assert(queue.enqueue(low) >= 0);
    assert(queue.dequeue() is null);

    assert(queue.enqueue(urgent) >= 0);
    assert(queue.dequeue() !is null);

    queue.set_capacity(5, 1, PCP.vo);
    assert(queue.dequeue() !is null);

    queue.abort_all();

    Packet deadline_packet;
    MonoTime base = MonoTime(1);
    deadline_packet.init!RawFrame(data[], base);
    deadline_packet.pcp = PCP.ca;
    QueuePolicy deadline;
    deadline.urgent_pcp = PCP.ic;
    deadline.priority_escalation_after = 100;
    deadline.deadline_after = 200;

    int deadline_tag = queue.enqueue(deadline_packet, null, &deadline);
    assert(deadline_tag > 0);
    queue.timeout_stale(base + 100.msecs);
    QueuedFrame* promoted = queue.dequeue();
    assert(promoted !is null);
    assert(promoted.tag == deadline_tag);
    assert(promoted.pcp == PCP.ic);
    assert(promoted.packet.pcp == PCP.ca);
    queue.complete(promoted.tag);

    deadline.priority_escalation_after = 300;
    deadline.deadline_after = 400;
    deadline_tag = queue.enqueue(deadline_packet, null, &deadline);
    assert(queue.is_queued(cast(ubyte)deadline_tag));
    queue.timeout_stale(base + 400.msecs);
    assert(!queue.is_queued(cast(ubyte)deadline_tag));

    Packet background;
    background.init!RawFrame(data[]);
    background.pcp = PCP.bk;
    background.dei = true;

    int newest_background_tag;
    int next_background_tag;
    foreach (i; 0 .. 32)
    {
        int tag = queue.enqueue(background);
        assert(tag > 0);
        next_background_tag = newest_background_tag;
        newest_background_tag = tag;
    }

    Packet routine;
    routine.init!RawFrame(data[]);
    routine.pcp = PCP.be;
    assert(queue.enqueue(routine) > 0);
    assert(!queue.is_queued(cast(ubyte)newest_background_tag));

    Packet important;
    important.init!RawFrame(data[]);
    important.pcp = PCP.vo;
    assert(queue.enqueue(important) > 0);
    assert(!queue.is_queued(cast(ubyte)next_background_tag));

    queue.abort_all();
}
