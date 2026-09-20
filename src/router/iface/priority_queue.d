module router.iface.priority_queue;

import urt.array;
import urt.mem;
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

        // the evicted frame's callback may resubmit into the slot it vacated
        if (_queued_count >= _max_queue_depth && (dei || !drop_lowest_dei() || _queued_count >= _max_queue_depth))
            return -1;

        QueuedFrame* frame = _pool.alloc();
        frame.packet = packet.clone();
        if (!frame.packet)
        {
            _pool.free(frame);
            return -1;
        }
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
                retire(detach_in_flight(i), state);
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
                retire(detach_in_flight(i), reason);
                return true;
            }
        }
        foreach (rank, ref bucket; _buckets)
        {
            foreach (i, frame; bucket[])
            {
                if (frame.tag == tag)
                {
                    retire(detach_queued(rank, i), reason);
                    return true;
                }
            }
        }
        return false;
    }

    void abort_all(MessageState reason = MessageState.aborted)
    {
        // a callback from either phase may resubmit, into a bucket already drained
        while (_queued_count != 0 || _in_flight.length != 0)
        {
            foreach (rank, ref bucket; _buckets)
            {
                while (bucket.length != 0)
                    retire(detach_queued(rank, 0), reason);
            }
            abort_all_in_flight(reason);
        }
    }

    void abort_all_in_flight(MessageState reason = MessageState.aborted)
    {
        while (_in_flight.length != 0)
            retire(detach_in_flight(0), reason);
    }

    void timeout_stale(MonoTime now)
    {
        promote_due(now);
        while (QueuedFrame* frame = detach_expired(now))
            retire(frame, MessageState.expired);
        while (QueuedFrame* frame = detach_timed_out(now))
            retire(frame, MessageState.timeout);
    }

    bool next_due(out MonoTime when) const pure
    {
        bool any;
        void consider(MonoTime t)
        {
            if (!any || t < when)
                when = t;
            any = true;
        }

        foreach (rank, ref bucket; _buckets)
        {
            foreach (frame; bucket[])
            {
                if (frame.deadline_after != 0)
                {
                    uint after = frame.deadline_after;
                    if (!frame.priority_escalated && frame.priority_escalation_after < after && pcp_priority_map[frame.urgent_pcp] > rank)
                        after = frame.priority_escalation_after;
                    consider(frame.packet.creation_time + after.msecs);
                }
                if (_queue_timeout != Duration())
                    consider(frame.enqueue_time + _queue_timeout);
            }
        }
        if (_transport_timeout != Duration())
        {
            foreach (frame; _in_flight[])
                consider(frame.dispatch_time + _transport_timeout);
        }
        return any;
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
                    retire(detach_queued(rank, i), MessageState.dropped);
                    return true;
                }
            }
        }
        return false;
    }

    QueuedFrame* detach_queued(size_t rank, size_t i)
    {
        QueuedFrame* frame = _buckets[rank][i];
        _buckets[rank].remove(i);
        --_queued_count;
        return frame;
    }

    QueuedFrame* detach_in_flight(size_t i)
    {
        QueuedFrame* frame = _in_flight[i];
        _in_flight.remove(i);
        --_in_flight_count;
        return frame;
    }

    QueuedFrame* detach_expired(MonoTime now)
    {
        foreach (rank, ref bucket; _buckets)
        {
            foreach (i, frame; bucket[])
            {
                if ((frame.deadline_after != 0 && packet_age_ms(frame, now) >= frame.deadline_after) ||
                    (_queue_timeout != Duration() && (now - frame.enqueue_time) >= _queue_timeout))
                    return detach_queued(rank, i);
            }
        }
        return null;
    }

    QueuedFrame* detach_timed_out(MonoTime now)
    {
        if (_transport_timeout == Duration())
            return null;
        foreach (i, frame; _in_flight[])
        {
            if ((now - frame.dispatch_time) >= _transport_timeout)
                return detach_in_flight(i);
        }
        return null;
    }

    // Detach and free before re-entry; reserve the tag until the caller finishes its bookkeeping.
    void retire(QueuedFrame* frame, MessageState state)
    {
        MessageCallback callback = frame.callback;
        ubyte tag = frame.tag;
        frame.packet.free_clone();
        _pool.free(frame);
        if (callback)
            callback(tag, state);
        _tags.free(tag);
    }
}

unittest
{
    import urt.mem.pagepool : page_pool_init, page_pool_deinit;

    bool owns_pool = page_pool_init();
    scope(exit) if (owns_pool) page_pool_deinit();

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
    MonoTime due;
    assert(queue.next_due(due) && due == base + 100.msecs);
    queue.timeout_stale(base + 100.msecs);
    assert(queue.next_due(due) && due == base + 200.msecs);
    QueuedFrame* promoted = queue.dequeue();
    assert(promoted !is null);
    assert(!queue.next_due(due));
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

    // a terminal callback may resubmit and re-enter: the frame it reports is already gone
    static struct Resubmit
    {
    nothrow @nogc:
        PriorityPacketQueue* queue;
        Packet* replacement;
        MonoTime now;
        int calls;
        int replacement_tag;

        void terminal(int tag, MessageState state)
        {
            ++calls;
            assert(!queue.is_queued(cast(ubyte)tag) && queue.find_in_flight(cast(ubyte)tag) is null);
            if (calls == 1)
            {
                replacement_tag = queue.enqueue(*replacement);
                queue.timeout_stale(now);
            }
        }
    }
    Resubmit r;
    r.queue = &queue;
    r.replacement = &routine;
    r.now = base + 1000.msecs;
    assert(queue.enqueue(deadline_packet, &r.terminal, &deadline) > 0);
    queue.timeout_stale(r.now);
    assert(r.calls == 1 && queue.is_queued(cast(ubyte)r.replacement_tag));

    r.calls = 0;
    assert(queue.enqueue(deadline_packet, &r.terminal, &deadline) > 0);
    queue.abort_all();
    assert(r.calls == 1 && !queue.has_pending);

    // the same from an in-flight frame's abort
    r.calls = 0;
    assert(queue.enqueue(important, &r.terminal) > 0);
    assert(queue.dequeue() !is null);
    queue.abort_all();
    assert(r.calls == 1 && !queue.has_pending && queue.in_flight_count == 0);

    // an evicted frame's callback refills its slot: the outer enqueue is refused, not admitted over the bound
    r.calls = 0;
    assert(queue.enqueue(background, &r.terminal) > 0);
    foreach (i; 1 .. 32)
        assert(queue.enqueue(routine) > 0);
    assert(queue.enqueue(important) < 0);
    size_t depth;
    foreach (pcp; 0 .. 8)
        depth += queue.queue_depth(cast(PCP)pcp);
    assert(r.calls == 1 && depth == 32);
    queue.abort_all();
}

unittest
{
    static struct Completion
    {
    nothrow @nogc:
        PriorityPacketQueue* queue;
        Packet* packet;
        int replacement;
        uint calls;

        void done(int tag, MessageState)
        {
            ++calls;
            assert(!queue.is_queued(cast(ubyte)tag));
            assert(queue.find_in_flight(cast(ubyte)tag) is null);
            assert(!queue.abort(cast(ubyte)tag));
            queue.complete(cast(ubyte)tag);
            replacement = queue.enqueue(*packet);
            assert(replacement > 0 && replacement != tag);
        }
    }

    foreach (mode; 0 .. 8)
    {
        ubyte[1] data;
        Packet packet;
        packet.init!RawFrame(data[]);
        PriorityPacketQueue queue;
        queue.init(1);
        Completion completion;
        completion.queue = &queue;
        completion.packet = &packet;
        packet.pcp = PCP.bk;
        packet.dei = true;
        int first = queue.enqueue(packet, &completion.done);
        assert(first == 1);
        packet.pcp = PCP.be;
        packet.dei = false;
        if (mode == 0 || mode == 2 || mode == 4 || mode == 7)
            assert(queue.dequeue() !is null);

        // Wrap the allocator while the first frame still owns tag 1.
        foreach (i; 0 .. (mode == 5 ? 223 : 254))
        {
            int tag = queue.enqueue(packet);
            assert(tag > 0);
            assert(queue.abort(cast(ubyte)tag));
        }

        MonoTime due;
        switch (mode)
        {
            case 0:
                queue.complete(cast(ubyte)first);
                break;
            case 1, 2:
                assert(queue.abort(cast(ubyte)first));
                break;
            case 3:
                queue.set_queue_timeout(1.msecs);
                assert(queue.next_due(due));
                queue.timeout_stale(due);
                break;
            case 4:
                queue.set_transport_timeout(1.msecs);
                assert(queue.next_due(due));
                queue.timeout_stale(due);
                break;
            case 5:
                foreach (i; 1 .. 32)
                    assert(queue.enqueue(packet) > 0);
                assert(queue.enqueue(packet) < 0);
                break;
            case 6:
                queue.abort_all();
                break;
            case 7:
                queue.abort_all_in_flight();
                break;
            default:
                assert(false);
        }
        assert(completion.calls == 1);
        assert(queue.is_queued(cast(ubyte)completion.replacement) == (mode != 6));
        queue.abort_all();
        assert(!queue.has_pending && queue.in_flight_count == 0);
    }
}
