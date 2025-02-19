-- Define the main protocol
local enms = Proto("ENMS", "ENMS Ethernet Protocol")

-- Define fields
local f_subtype = ProtoField.uint16("enms.subtype", "Sub-Type", base.HEX, { [0x0010] = "MBoE", [0x0020] = "CANoE", [0x0030] = "ZBoE", [0x0040] = "TWCoE" })
local f_payload = ProtoField.bytes("enms.payload", "Payload Data")

-- MBoE (Modbus over Ethernet) fields
local f_mboe_address = ProtoField.uint8("mboe.address", "Address", base.DEC)
local f_mboe_direction = ProtoField.uint8("mboe.type", "Type", base.DEC, { [1] = "Request", [2] = "Response" })
local f_mboe_sequence = ProtoField.uint16("mboe.sequence", "Sequence", base.DEC)

-- CANoE (CAN over Ethernet) fields
local f_canoe_frame = ProtoField.bytes("canoe.frame", "CAN Frame (SocketCAN)")

-- TWCoE (Tesla-TWC over Ethernet) fields
local f_twcoe_cmd = ProtoField.uint16("twcoe.command", "Command Code", base.HEX)
local f_twcoe_sender = ProtoField.uint16("twcoe.sender", "Sender ID", base.HEX)
local f_twcoe_payload = ProtoField.bytes("twcoe.payload", "TWC Payload Data")

enms.fields = { f_subtype, f_payload, f_mboe_address, f_mboe_direction, f_mboe_sequence, f_canoe_frame, f_twcoe_cmd, f_twcoe_sender, f_twcoe_payload }

-- Function to dissect MBoE (Modbus over Ethernet)
local function dissect_mboe(buffer, pinfo, tree)
    if buffer:len() < 5 then return end  -- ensure at least header + one PDU byte

    local mboe_subtree = tree:add(enms, buffer(), "MBoE - Modbus over Ethernet")

    -- Show fields in the packet details
    mboe_subtree:add(f_mboe_sequence,  buffer:range(0,2))
    mboe_subtree:add(f_mboe_direction, buffer:range(2,1))
--    mboe_subtree:add(f_mboe_address,   buffer:range(3,1))

    -- Hand off to the built-in 'modbus' dissector
    local modbus_tcp_dissector = Dissector.get("mbrtu")
    if modbus_tcp_dissector then
        -- Call the Modbus dissector
        modbus_tcp_dissector:call(buffer:range(3):tvb(), pinfo, tree)

        -- Update the protocol column
        pinfo.cols.protocol = "Modbus MBoE"
    else
        mboe_subtree:add_expert_info(PI_UNDECODED, PI_WARN, "Modbus RTU dissector not found")
    end
end

---- Function to dissect CANOE (CAN over Ethernet)
--local function dissect_canoe(buffer, pinfo, tree)
--    if buffer:len() < 16 then return end  -- Typical minimum CAN frame size
--
--    local canoe_subtree = tree:add(enms, buffer(), "CANoE - CAN over Ethernet")
--    canoe_subtree:add(f_canoe_frame, buffer())
--
--    -- Retrieve the CAN dissector correctly
--    local encap_table = DissectorTable.get("wtap_encap")
--    local can_dissector = encap_table:get_dissector(wtap_encaps.SOCKETCAN)
--
--    if can_dissector then
--        can_dissector:call(buffer:tvb(), pinfo, tree)
--    else
--        canoe_subtree:add_expert_info(PI_UNDECODED, PI_WARN, "CAN dissector not found")
--    end
--end

-- Function to dissect TWCoE (Tesla-TWC over Ethernet)
local function dissect_twcoe(buffer, pinfo, tree)
    if buffer:len() < 4 then return end

    local twcoe_subtree = tree:add(enms, buffer(), "TWCoE - Tesla-TWC over Ethernet")
    twcoe_subtree:add(f_twcoe_cmd, buffer(0,2))
    twcoe_subtree:add(f_twcoe_sender, buffer(2,2))

    local cmd = buffer(0,2):uint()
    local payload = buffer(4, 11)  -- Remaining 11 bytes

    -- Command-specific parsing
    if cmd == 0x1001 then
        twcoe_subtree:add(f_twcoe_payload, payload, "Handshake Request")
    elseif cmd == 0x1002 then
        twcoe_subtree:add(f_twcoe_payload, payload, "Handshake Response")
    elseif cmd == 0x2001 then
        twcoe_subtree:add(f_twcoe_payload, payload, "Status Update")
    elseif cmd == 0x3001 then
        twcoe_subtree:add(f_twcoe_payload, payload, "Charge Request")
    else
        twcoe_subtree:add(f_twcoe_payload, payload, "Unknown Command")
    end
end

-- Main dissector function
function enms.dissector(buffer, pinfo, tree)
    if buffer:len() < 2 then return end

    pinfo.cols.protocol = "ENMS"

    local subtree = tree:add(enms, buffer(), "ENMS Protocol")
    local subtype = buffer(0,2):uint()
    subtree:add(f_subtype, buffer(0,2))

    local payload = buffer(2):tvb()

    if subtype == 0x0010 then
        dissect_mboe(payload, pinfo, subtree)
    elseif subtype == 0x0020 then
--        dissect_canoe(payload, pinfo, subtree)
        -- Call the SOCKETCAN dissector
        local encap_table = DissectorTable.get("wtap_encap")
        local can_dissector = encap_table:get_dissector(wtap_encaps.SOCKETCAN)

        if can_dissector then
            can_dissector:call(payload, pinfo, tree)
        else
            subtree:add_expert_info(PI_UNDECODED, PI_WARN, "SOCKETCAN dissector not found")
        end
    elseif subtype == 0x0040 then
        dissect_twcoe(payload, pinfo, subtree)
    else
        subtree:add(f_payload, payload, "Unknown Sub-Type")
    end
end

-- Register the dissector for Ethertype 0x88B5
DissectorTable.get("ethertype"):add(0x88B5, enms)
