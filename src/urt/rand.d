module urt.rand;


version = PCG;
//version = MersenneTwister;

nothrow @nogc:


version (PCG)
{
    struct Rand
    {
        ulong state;
        ulong inc;
    }

    void srand(ulong initstate, ulong initseq, Rand* rng = null)
    {
        if (!rng)
            rng = &globalRand;

        rng.state = 0U;
        rng.inc = (initseq << 1u) | 1u;
        pcg_setseq_64_step_r(rng);
        rng.state += initstate;
        pcg_setseq_64_step_r(rng);
    }

    uint rand(Rand* rng = null)
    {
        if (!rng)
            rng = &globalRand;

        ulong oldstate = rng.state;
        // Advance internal state
        rng.state = oldstate*6364136223846793005 + (rng.inc|1);
        // Calculate output function (XSH RR), uses old state for max ILP
        uint xorshifted = cast(uint)(((oldstate >> 18) ^ oldstate) >> 27);
        uint rot = oldstate >> 59;
        return (xorshifted >> rot) | (xorshifted << ((-rot) & 31));
    }

private:
    enum ulong PCG_DEFAULT_MULTIPLIER_64 = 6364136223846793005;

    static Rand globalRand = () { Rand r; srand(0xBAADF00D1337B00B, 0xABCDEF01, &r); return r; }();

    void pcg_setseq_64_step_r(Rand* rng)
    {
        rng.state = rng.state*PCG_DEFAULT_MULTIPLIER_64 + rng.inc;
    }

    package void initRand()
    {
        import urt.time;
        srand(getTime().ticks, cast(size_t)&globalRand, &globalRand);
    }
}

version (MersenneTwister)
{
    // An implementation of the MT19937 Algorithm for the Mersenne Twister
    // by Evan Sultanik.  Based upon the pseudocode in: M. Matsumoto and
    // T. Nishimura, "Mersenne Twister: A 623-dimensionally
    // equidistributed uniform pseudorandom number generator," ACM
    // Transactions on Modeling and Computer Simulation Vol. 8, No. 1,
    // January pp.3-30 1998.
    //
    // http://www.sultanik.com/Mersenne_twister

    struct Rand
    {
        uint[STATE_VECTOR_LENGTH] mt;
        int index;
    }

    // Creates a new random number generator from a given seed.
    void srand(uint seed, Rand* rand = null)
    {
        if (!rand)
            rand = &globalRand;

        // Set initial seeds to mt[STATE_VECTOR_LENGTH] using the generator
        // from Line 25 of Table 1 in: Donald Knuth, "The Art of Computer
        // Programming," Vol. 2 (2nd Ed.) pp.102.
        rand.mt[0] = seed & 0xffffffff;
        for(rand.index=1; rand.index<STATE_VECTOR_LENGTH; rand.index++) {
            rand.mt[rand.index] = (6069 * rand.mt[rand.index-1]) & 0xffffffff;
        }
    }

    // Generates a pseudo-randomly generated long.
    uint rand(Rand* rand = null)
    {
        if (!rand)
            rand = &globalRand;

        __gshared immutable uint[2] mag = [ 0x0, 0x9908b0df ]; // mag[x] = x * 0x9908b0df for x = 0,1
        uint y;
        if(rand.index >= STATE_VECTOR_LENGTH || rand.index < 0)
        {
            // generate STATE_VECTOR_LENGTH words at a time
            int kk;
            if(rand.index >= STATE_VECTOR_LENGTH+1 || rand.index < 0)
                srand(4357, rand);
            for(kk=0; kk<STATE_VECTOR_LENGTH-STATE_VECTOR_M; kk++)
            {
                y = (rand.mt[kk] & UPPER_MASK) | (rand.mt[kk+1] & LOWER_MASK);
                rand.mt[kk] = rand.mt[kk+STATE_VECTOR_M] ^ (y >> 1) ^ mag[y & 0x1];
            }
            for(; kk<STATE_VECTOR_LENGTH-1; kk++)
            {
                y = (rand.mt[kk] & UPPER_MASK) | (rand.mt[kk+1] & LOWER_MASK);
                rand.mt[kk] = rand.mt[kk+(STATE_VECTOR_M-STATE_VECTOR_LENGTH)] ^ (y >> 1) ^ mag[y & 0x1];
            }
            y = (rand.mt[STATE_VECTOR_LENGTH-1] & UPPER_MASK) | (rand.mt[0] & LOWER_MASK);
            rand.mt[STATE_VECTOR_LENGTH-1] = rand.mt[STATE_VECTOR_M-1] ^ (y >> 1) ^ mag[y & 0x1];
            rand.index = 0;
        }
        y = rand.mt[rand.index++];
        y ^= (y >> 11);
        y ^= (y << 7) & TEMPERING_MASK_B;
        y ^= (y << 15) & TEMPERING_MASK_C;
        y ^= (y >> 18);
        return y;
    }

    T rand(T)(Rand* rand = null)
        if (isSomeInt!T)
    {
        static if (is(T == ulong) || is(T == long))
            return cast(T)((cast(ulong)rand(rand) << 32) | rand(rand));
        else
            return cast(T)rand(rand);
    }

    T rand(T)(Rand* rand = null)
        if (isSomeFloat!T)
    {
        static if (is(T == float))
            return cast(T)(rand(rand) / uint.max);
        else static if (is(T == double))
            return cast(T)(rand!ulong(rand) / ulong.max);
        else static assert(false);
    }


private:

    enum STATE_VECTOR_LENGTH = 624;
    enum STATE_VECTOR_M =  397; // changes to STATE_VECTOR_LENGTH also require changes to this

    enum UPPER_MASK = 0x80000000;
    enum LOWER_MASK = 0x7fffffff;
    enum TEMPERING_MASK_B = 0x9d2c5680;
    enum TEMPERING_MASK_C = 0xefc60000;

    static Rand globalRand;

    package void initRand()
    {
        import urt.time;
        srand(getTime().ticks & uint.max, &globalRand);
    }
}
