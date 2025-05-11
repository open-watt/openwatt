module urt.processor;

version (LittleEndian)
    enum LittleEndian = true;
else
    enum LittleEndian = false;

version (X86_64)
{
    version = Intel;
    enum string ProcessorFamily = "x86_64";
}
else version (X86)
{
    version = Intel;
    enum string ProcessorFamily = "x86";
}
else version (AArch64)
    enum string ProcessorFamily = "ARM64";
else version (ARM)
{
    enum string ProcessorFamily = "ARM";
    enum string ProcessorName = __traits(targetCPU);

    struct ProcFeaturesT
    {
        bool crc = __traits(targetHasFeature, "crc");                                   // Enable support for CRC instructions.
        bool crypto = __traits(targetHasFeature, "crypto");                             // Enable support for Cryptography extensions.
        bool d32 = __traits(targetHasFeature, "d32");                                   // Extend FP to 32 double registers.
        bool dotprod = __traits(targetHasFeature, "dotprod");                           // Enable support for dot product instructions.
        bool fuse_aes = __traits(targetHasFeature, "fuse-aes");                         // CPU fuses AES crypto operations.
        bool fp64 = __traits(targetHasFeature, "fp64");                                 // Floating point unit supports double precision.
        bool neon = __traits(targetHasFeature, "neon");                                 // Enable NEON instructions.
        bool neon_fpmovs = __traits(targetHasFeature, "neon-fpmovs");                   // Convert VMOVSR, VMOVRS, VMOVS to NEON.
        bool no_branch_predictor = __traits(targetHasFeature, "no-branch-predictor");   // Has no branch predictor.
        bool perfmon = __traits(targetHasFeature, "perfmon");                           // Enable support for Performance Monitor extensions.
        bool sha2 = __traits(targetHasFeature, "sha2");                                 // Enable SHA1 and SHA256 support.
        bool strict_align = __traits(targetHasFeature, "strict-align");                 // Disallow all unaligned memory access.
        bool thumb = __traits(targetHasFeature, "thumb-mode");                          // Thumb mode.
        bool thumb2 = __traits(targetHasFeature, "thumb2");                             // Enable Thumb2 instructions.
        bool v4t = __traits(targetHasFeature, "v4t");                                   // Support ARM v4T instructions.
        bool v5t = __traits(targetHasFeature, "v5t");                                   // Support ARM v5T instructions.
        bool v5te = __traits(targetHasFeature, "v5te");                                 // Support ARM v5TE, v5TEj, and v5TExp instructions.
        bool v6 = __traits(targetHasFeature, "v6");                                     // Support ARM v6 instructions.
        bool v6k = __traits(targetHasFeature, "v6k");                                   // Support ARM v6k instructions.
        bool v6m = __traits(targetHasFeature, "v6m");                                   // Support ARM v6M instructions.
        bool v6t2 = __traits(targetHasFeature, "v6t2");                                 // Support ARM v6t2 instructions.
        bool v7 = __traits(targetHasFeature, "v7");                                     // Support ARM v7 instructions.
        bool v7clrex = __traits(targetHasFeature, "v7clrex");                           // Has v7 clrex instruction.
        bool v8 = __traits(targetHasFeature, "v8");                                     // Support ARM v8 instructions.
        bool vfp2 = __traits(targetHasFeature, "vfp2");                                 // Enable VFP2 instructions.
        bool vfp2sp = __traits(targetHasFeature, "vfp2sp");                             // Enable VFP2 instructions with no double precision.
        bool vfp3 = __traits(targetHasFeature, "vfp3");                                 // Enable VFP3 instructions.
        bool vfp3d16 = __traits(targetHasFeature, "vfp3d16");                           // Enable VFP3 instructions with only 16 d-registers.
        bool vfp3d16sp = __traits(targetHasFeature, "vfp3d16sp");                       // Enable VFP3 instructions with only 16 d-registers and no double precision.
        bool vfp3sp = __traits(targetHasFeature, "vfp3sp");                             // Enable VFP3 instructions with no double precision.
        bool vfp4 = __traits(targetHasFeature, "vfp4");                                 // Enable VFP4 instructions.
        bool vfp4d16 = __traits(targetHasFeature, "vfp4d16");                           // Enable VFP4 instructions with only 16 d-registers.
        bool vfp4d16sp = __traits(targetHasFeature, "vfp4d16sp");                       // Enable VFP4 instructions with only 16 d-registers and no double precision.
        bool vfp4sp = __traits(targetHasFeature, "vfp4sp");                             // Enable VFP4 instructions with no double precision.
        bool zcz = __traits(targetHasFeature, "zcz");                                   // Has zero-cycle zeroing instructions.
    }
    enum ProcFeatures = ProcFeaturesT();
}
else version (RISCV64)
    enum string ProcessorFamily = "RISCV64";
else version (RISCV32)
    enum string ProcessorFamily = "RISCV";
else version (Xtensa)
    enum string ProcessorFamily = "Xtensa";
else
    static assert(0, "Unsupported processor");

version (X86)
    enum SupportUnalignedLoadStore = true;
else version (X86_64)
    enum SupportUnalignedLoadStore = true;
else version (AArch64)
    enum SupportUnalignedLoadStore = true;
else version (ARM)
{
    enum SupportUnalignedLoadStore = !ProcFeatures.strict_align;
}
else
{
    // TODO: I think MIPS R6 can do native unalogned loads/stores
    enum SupportUnalignedLoadStore = false;
}

// Different arch may define this differently...
// question is; is it worth a branch to avoid a redundant store?
enum bool BranchMoreExpensiveThanStore = false;
