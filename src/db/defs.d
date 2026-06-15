module db.defs;

// Boundary types for the database world.
//
// The database is treated like an inter-process / remote database: the
// frontend pushes samples in and issues fetch requests, and the work happens
// on the far side of a queue (another thread today, possibly another core or a
// genuine remote endpoint later). Everything that crosses the boundary is plain
// POD with no pointers into the frontend data model, so the same messages can
// travel over a thread channel, a cross-core ring, or a wire.

nothrow @nogc:


alias SeriesId = uint;

enum SeriesId invalid_series = 0;


// TODO: records should be all kinds of things!
struct Sample
{
    ulong time;   // unix ns
    double value;
}


enum IngestKind : ubyte
{
    sample,
    block,
    open_series,
    close_series,
}

// One message in the frontend -> db ingest stream.
struct IngestMsg
{
    IngestKind kind;
    SeriesId series;
    union
    {
        struct // sample
        {
            ulong time;
            double value;
        }
        struct // block: a run of in-order samples (heap copy, freed after consume)
        {
            const(Sample)* samples;
            size_t count;
        }
        struct // open_series
        {
            const(char)* filename; // heap copy owned by the engine after consume
            size_t filename_len;
        }
    }
}

enum QueryMode : ubyte
{
    raw,    // mean per time bucket, stamped with the bucket's last real time
    graph,  // time-weighted sample-and-hold per bucket, with the value held at
            // the left edge seeded as the first point (for line/area charts)
}

struct QueryReq
{
    uint ticket;
    SeriesId series;
    ulong from;        // unix ns, inclusive
    ulong to;          // unix ns, inclusive
    uint max_points;   // 0 = no downsampling
    QueryMode mode;
}

struct QueryDone
{
    uint ticket;
    const(Sample)* data; // const pointee so the message copies cleanly through the ring
    uint count;
}

// A db -> frontend log notice. The worker can't safely touch the logging
// sinks, so it ships text back and the frontend logs it on the main thread.
// `text` is a heap copy the frontend frees.
struct DbNotice
{
    const(char)* text;
    uint len;
}
