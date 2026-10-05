module driver.bl808.ipc_ids;

// Ids in the BL808's inter-core mailbox; the mailbox reserves 0.
enum IpcId : ubyte
{
    xram_frame = 1,
    xram_space,
}
