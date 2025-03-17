module urt.processor;


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
else version (ARM64)
    enum string ProcessorFamily = "ARM64";
else version (ARM)
    enum string ProcessorFamily = "ARM";
else version (RISCV64)
    enum string ProcessorFamily = "RISCV64";
else version (RISCV32)
    enum string ProcessorFamily = "RISCV";
else version (Xtensa)
    enum string ProcessorFamily = "Xtensa";
else
    static assert(0, "Unsupported processor");


// Different arch may define this differently...
// question is; is it worth a branch to avoid a redundant store?
enum bool BranchMoreExpensiveThanStore = false;
