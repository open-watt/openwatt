module urt.rand;

version = PCG;


nothrow @nogc:


version (PCG)
{
    struct Rand
    {
        ulong state;
        ulong inc;
    }

    void srand(ulong initstate, ulong initseq)
    {
        srand(initstate, initseq, globalRand);
    }

    void srand(ulong initstate, ulong initseq, ref Rand rng) pure
    {
        rng.state = 0U;
        rng.inc = (initseq << 1u) | 1u;
        pcg_setseq_64_step_r(rng);
        rng.state += initstate;
        pcg_setseq_64_step_r(rng);
    }

    uint rand()
    {
        return rand(globalRand);
    }

    uint rand(ref Rand rng) pure
    {
        ulong oldstate = rng.state;
        // Advance internal state
        rng.state = oldstate * PCG_DEFAULT_MULTIPLIER_64 + (rng.inc | 1);
        // Calculate output function (XSH RR), uses old state for max ILP
        uint xorshifted = cast(uint)(((oldstate >> 18) ^ oldstate) >> 27);
        uint rot = oldstate >> 59;
        return (xorshifted >> rot) | (xorshifted << ((-rot) & 31));
    }

private:
    enum ulong PCG_DEFAULT_MULTIPLIER_64 = 6364136223846793005;
    enum Rand initState = () { Rand r; srand(0xBAADF00D1337B00B, 0xABCDEF01, r); return r; }();

    Rand globalRand = initState;

    void pcg_setseq_64_step_r(ref Rand rng) pure
    {
        rng.state = rng.state * PCG_DEFAULT_MULTIPLIER_64 + rng.inc;
    }

    package void initRand()
    {
        import urt.time;
        srand(getTime().ticks, cast(size_t)&globalRand);
    }
}
