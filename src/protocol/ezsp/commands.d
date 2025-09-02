module protocol.ezsp.commands;

nothrow @nogc:


// HACK: what is this? Why the spec randomly uses this for signal powers?
alias int8s = byte;


// Identifies a configuration value.
enum EzspConfigId : ubyte {
    PACKET_BUFFER_COUNT = 0x01, // The NCP no longer supports configuration of packet buffer count at runtime using this parameter. Packet buffers must be configured using the EMBER_PACKET_BUFFER_COUNT macro when building the NCP project.
    NEIGHBOR_TABLE_SIZE = 0x02, // The maximum number of router neighbors the stack can keep track of. A neighbor is a node within radio range.
    APS_UNICAST_MESSAGE_COUNT = 0x03, // The maximum number of APS retried messages the stack can be transmitting at any time.
    BINDING_TABLE_SIZE = 0x04, // The maximum number of non-volatile bindings supported by the stack.
    ADDRESS_TABLE_SIZE = 0x05, // The maximum number of EUI64 to network address associations that the stack can maintain for the application. (Note, the total number of such address associations maintained by the NCP is the sum of the value of this setting and the value of EZSP_CONFIG_TRUST_CENTER_ADDRESS_CACHE_SIZE.).
    MULTICAST_TABLE_SIZE = 0x06, // The maximum number of multicast groups that the device may be a member of.
    ROUTE_TABLE_SIZE = 0x07, // The maximum number of destinations to which a node can route messages. This includes both messages originating at this node and those relayed for others.
    DISCOVERY_TABLE_SIZE = 0x08, // The number of simultaneous route discoveries that a node will support.
    STACK_PROFILE = 0x0C, // Specifies the stack profile.
    SECURITY_LEVEL = 0x0D, // The security level used for security at the MAC and network layers. The supported values are 0 (no security) and 5 (payload is encrypted and a four-byte MIC is used for authentication).
    MAX_HOPS = 0x10, // The maximum number of hops for a message.
    MAX_END_DEVICE_CHILDREN = 0x11, // The maximum number of end device children that a router will support.
    INDIRECT_TRANSMISSION_TIMEOUT = 0x12, // The maximum amount of time that the MAC will hold a message for indirect transmission to a child.
    END_DEVICE_POLL_TIMEOUT = 0x13, // The maximum amount of time that an end device child can wait between polls. If no poll is heard within this timeout, then the parent removes the end device from its tables. Value range 0-14. The timeout corresponding to a value of zero is 10 seconds. The timeout corresponding to a nonzero value N is 2^N minutes, ranging from 2^1 = 2 minutes to 2^14 = 16384 minutes.
    TX_POWER_MODE = 0x17, // Enables boost power mode and/or the alternate transmitter output.
    DISABLE_RELAY = 0x18, // 0: Allow this node to relay messages. 1: Prevent this node from relaying messages.
    TRUST_CENTER_ADDRESS_CACHE_SIZE = 0x19, // The maximum number of EUI64 to network address associations that the Trust Center can maintain. These address cache entries are reserved for and reused by the Trust Center when processing device join/rejoin authentications. This cache size limits the number of overlapping joins the Trust Center can process within a narrow time window (e.g. two seconds), and thus should be set to the maximum number of near simultaneous joins the Trust Center is expected to accommodate. (Note, the total number of such address associations maintained by the NCP is the sum of the value of this setting and the value of EZSP_CONFIG_ADDRESS_TABLE_SIZE.).
    SOURCE_ROUTE_TABLE_SIZE = 0x1A, // The size of the source route table.
    FRAGMENT_WINDOW_SIZE = 0x1C, // The number of blocks of a fragmented message that can be sent in a single window.
    FRAGMENT_DELAY_MS = 0x1D, // The time the stack will wait (in milliseconds) between sending blocks of a fragmented message.
    KEY_TABLE_SIZE = 0x1E, // The size of the Key Table used for storing individual link keys (if the device is a Trust Center) or Application Link Keys (if the device is a normal node).
    APS_ACK_TIMEOUT = 0x1F, // The APS ACK timeout value. The stack waits this amount of time between resends of APS retried messages.
    BEACON_JITTER_DURATION = 0x20, // The duration of a beacon jitter, in the units used by the 15.4 scan parameter (((1 << duration) + 1) * 15ms), when responding to a beacon request.
    PAN_ID_CONFLICT_REPORT_THRESHOLD = 0x22, // The number of PAN id conflict reports that must be received by the network manager within one minute to trigger a PAN id change.
    REQUEST_KEY_TIMEOUT = 0x24, // The timeout value in minutes for how long the Trust Center or a normal node waits for the ZigBee Request Key to complete. On the Trust Center this controls whether or not the device buffers the request, waiting for a matching pair of ZigBee Request Key. If the value is non-zero, the Trust Center buffers and waits for that amount of time. If the value is zero, the Trust Center does not buffer the request and immediately responds to the request. Zero is the most compliant behavior.
    CERTIFICATE_TABLE_SIZE = 0x29, // This value indicates the size of the runtime modifiable certificate table. Normally certificates are stored in MFG tokens but this table can be used to field upgrade devices with new Smart Energy certificates. This value cannot be set, it can only be queried.
    APPLICATION_ZDO_FLAGS = 0x2A, // This is a bitmask that controls which incoming ZDO request messages are passed to the application. The bits are defined in the EmberZdoConfigurationFlags enumeration. To see if the application is required to send a ZDO response in reply to an incoming message, the application must check the APS options bitfield within the incomingMessageHandler callback to see if the EMBER_APS_OPTION_ZDO_RESPONSE_REQUIRED flag is set.
    BROADCAST_TABLE_SIZE = 0x2B, // The maximum number of broadcasts during a single broadcast timeout period.
    MAC_FILTER_TABLE_SIZE = 0x2C, // The size of the MAC filter list table.
    SUPPORTED_NETWORKS = 0x2D, // The number of supported networks.
    SEND_MULTICASTS_TO_SLEEPY_ADDRESS = 0x2E, // Whether multicasts are sent to the RxOnWhenIdle=true address (0xFFFD) or the sleepy broadcast address (0xFFFF). The RxOnWhenIdle=true address is the ZigBee compliant destination for multicasts.
    ZLL_GROUP_ADDRESSES = 0x2F, // ZLL group address initial configuration.
    ZLL_RSSI_THRESHOLD = 0x30, // ZLL rssi threshold initial configuration.
    MTORR_FLOW_CONTROL = 0x33, // Toggles the MTORR flow control in the stack.
    RETRY_QUEUE_SIZE = 0x34, // Setting the retry queue size. Applies to all queues. Default value in the sample applications is 16.
    NEW_BROADCAST_ENTRY_THRESHOLD = 0x35, // Setting the new broadcast entry threshold. The number(BROADCAST_TABLE_SIZE - NEW_BROADCAST_ENTRY_THRESHOLD) of broadcast table entries are reserved for relaying the broadcast messages originated on other devices. The local device will fail to originate a broadcast message after this threshold is reached. Setting this value to BROADCAST_TABLE_SIZE and greater will effectively kill this limitation.
    TRANSIENT_KEY_TIMEOUT_S = 0x36, // The length of time, in seconds, that a trust center will store a transient link key that a device can use to join its network. A transient key is added with a call to emberAddTransientLinkKey. After the transient key is added, it will be removed once this amount of time has passed. A joining device will not be able to use that key to join until it is added again on the trust center. The default value is 300 seconds, i.e., 5 minutes.
    BROADCAST_MIN_ACKS_NEEDED = 0x37, // The number of passive acknowledgements to record from neighbors before we stop re-transmitting broadcasts
    TC_REJOINS_USING_WELL_KNOWN_KEY_TIMEOUT_S = 0x38, // The length of time, in seconds, that a trust center will allow a Trust Center (insecure) rejoin for a device that is using the well-known link key. This timeout takes effect once rejoins using the well-known key has been allowed. This command updates the sli_zigbee_allow_tc_rejoins_using_well_known_key_timeout_sec value.
    CTUNE_VALUE = 0x39, // Valid range of a CTUNE value is 0x0000-0x01FF. Higher order bits (0xFE00) of the 16-bit value are ignored.
    ASSUME_TC_CONCENTRATOR_TYPE = 0x40, // To configure non trust center node to assume a concentrator type of the trust center it join to, until it receive many-to-one route request from the trust center. For the trust center node, concentrator type is configured from the concentrator plugin. The stack by default assumes trust center be a low RAM concentrator that make other devices send route record to the trust center even without receiving a many-to-one route request. The default concentrator type can be changed by setting appropriate EmberAssumeTrustCenterConcentratorType config value.
    GP_PROXY_TABLE_SIZE = 0x41, // This is green power proxy table size. This value is read-only and cannot be set at runtime
    GP_SINK_TABLE_SIZE = 0x42, // This is green power sink table size. This value is read-only and cannot be set at runtime
}

// Identifies a value.
enum EzspValueId : ubyte {
    TOKEN_STACK_NODE_DATA = 0x00, // The contents of the node data stack token.
    MAC_PASSTHROUGH_FLAGS = 0x01, // The types of MAC passthrough messages that the host wishes to receive.
    EMBERNET_PASSTHROUGH_SOURCE_ADDRESS = 0x02, // The source address used to filter legacy EmberNet messages when the EMBER_MAC_PASSTHROUGH_EMBERNET_SOURCE flag is set in EZSP_VALUE_MAC_PASSTHROUGH_FLAGS.
    FREE_BUFFERS = 0x03, // The number of available internal RAM general purpose buffers. Read only.
    UART_SYNCH_CALLBACKS = 0x04, // Selects sending synchronous callbacks in ezsp-uart.
    MAXIMUM_INCOMING_TRANSFER_SIZE = 0x05, // The maximum incoming transfer size for the local node. Default value is set to 82 and does not use fragmentation. Sets the value in Node Descriptor. To set, this takes the input of a uint8 array of length 2 where you pass the lower byte at index 0 and upper byte at index 1.
    MAXIMUM_OUTGOING_TRANSFER_SIZE = 0x06, // The maximum outgoing transfer size for the local node. Default value is set to 82 and does not use fragmentation. Sets the value in Node Descriptor. To set, this takes the input of a uint8 array of length 2 where you pass the lower byte at index 0 and upper byte at index 1.
    STACK_TOKEN_WRITING = 0x07, // A bool indicating whether stack tokens are written to persistent storage as they change.
    STACK_IS_PERFORMING_REJOIN = 0x08, // A read-only value indicating whether the stack is currently performing a rejoin.
    MAC_FILTER_LIST = 0x09, // A list of EmberMacFilterMatchData values.
    EXTENDED_SECURITY_BITMASK = 0x0A, // The Ember Extended Security Bitmask.
    NODE_SHORT_ID = 0x0B, // The node short ID.
    DESCRIPTOR_CAPABILITY = 0x0C, // The descriptor capability of the local node. Write only.
    STACK_DEVICE_REQUEST_SEQUENCE = 0x0D, // The stack device request sequence number of the local node.
    RADIO_HOLD_OFF = 0x0E, // Enable or disable radio hold-off.
    ENDPOINT_FLAGS = 0x0F, // The flags field associated with the endpoint data.
    MFG_SECURITY_CONFIG = 0x10, // Enable/disable the Mfg security config key settings.
    VERSION_INFO = 0x11, // Retrieves the version information from the stack on the NCP.
    NEXT_HOST_REJOIN_REASON = 0x12, // This will get/set the rejoin reason noted by the host for a subsequent call to emberFindAndRejoinNetwork(). After a call to emberFindAndRejoinNetwork() the host's rejoin reason will be set to EMBER_REJOIN_REASON_NONE. The NCP will store the rejoin reason used by the call to emberFindAndRejoinNetwork().Application is not required to do anything with this value. The App Framework sets this for cases of emberFindAndRejoinNetwork that it initiates, but if the app is invoking a rejoin directly, it should/can set this value to aid in debugging of any rejoin state machine issues over EZSP logs after the fact. The NCP doesn't do anything with this value other than cache it so you can read it later.
    LAST_REJOIN_REASON = 0x13, // This is the reason that the last rejoin took place. This value may only be retrieved, not set. The rejoin may have been initiated by the stack (NCP) or the application (host). If a host initiated a rejoin the reason will be set by default to EMBER_REJOIN_DUE_TO_APP_EVENT_1. If the application wishes to denote its own rejoin reasons it can do so by calling ezspSetValue(EMBER_VALUE_HOST_REJOIN_REASON, EMBER_REJOIN_DUE_TO_APP_EVENT_X). X is a number corresponding to one of the app events defined. If the NCP initiated a rejoin it will record this value internally for retrieval by ezspGetValue(EZSP_VALUE_REAL_REJOIN_REASON).
    NEXT_ZIGBEE_SEQUENCE_NUMBER = 0x14, // The next ZigBee sequence number.
    CCA_THRESHOLD = 0x15, // CCA energy detect threshold for radio.
    SET_COUNTER_THRESHOLD = 0x17, // The threshold value for a counter
    RESET_COUNTER_THRESHOLDS = 0x18, // Resets all counters thresholds to 0xFF
    CLEAR_COUNTERS = 0x19, // Clears all the counters
    CERTIFICATE_283K1 = 0x1A, // The node's new certificate signed by the CA.
    PUBLIC_KEY_283K1 = 0x1B, // The Certificate Authority's public key.
    PRIVATE_KEY_283K1 = 0x1C, // The node's new static private key.
    NWK_FRAME_COUNTER = 0x23, // The NWK layer security frame counter value
    APS_FRAME_COUNTER = 0x24, // The APS layer security frame counter value. Managed by the stack. Users should not set these unless doing backup and restore.
    RETRY_DEVICE_TYPE = 0x25, // Sets the device type to use on the next rejoin using device type
    ENABLE_R21_BEHAVIOR = 0x29, // Setting this byte enables R21 behavior on the NCP.
    ANTENNA_MODE = 0x30, // Configure the antenna mode(0-don't switch,1-primary,2-secondary,3-TX antenna diversity).
    ENABLE_PTA = 0x31, // Enable or disable packet traffic arbitration.
    PTA_OPTIONS = 0x32, // Set packet traffic arbitration configuration options.
    MFGLIB_OPTIONS = 0x33, // Configure manufacturing library options (0-non-CSMA transmits,1-CSMA transmits). To be used with Manufacturing library.
    USE_NEGOTIATED_POWER_BY_LPD = 0x34, // Sets the flag to use either negotiated power by link power delta (LPD) or fixed power value provided by user while forming/joining a network for packet transmissions on sub-ghz interface. This is mainly for testing purposes.
    PTA_PWM_OPTIONS = 0x35, // Set packet traffic arbitration PWM options.
    PTA_DIRECTIONAL_PRIORITY_PULSE_WIDTH = 0x36, // Set packet traffic arbitration directional priority pulse width in microseconds.
    PTA_PHY_SELECT_TIMEOUT = 0x37, // Set packet traffic arbitration phy select timeout(ms).
    ANTENNA_RX_MODE = 0x38, // Configure the RX antenna mode: (0-do not switch; 1-primary; 2-secondary; 3-RX antenna diversity).
    NWK_KEY_TIMEOUT = 0x39, // Configure the timeout to wait for the network key before failing a join. Acceptable timeout range [3,255]. Value is in seconds.
    FORCE_TX_AFTER_FAILED_CCA_ATTEMPTS = 0x3A, // The number of failed CSMA attempts due to failed CCA made by the MAC before continuing transmission with CCA disabled. This is the same as calling the emberForceTxAfterFailedCca(uint8_t csmaAttempts) API. A value of 0 disables the feature
    TRANSIENT_KEY_TIMEOUT_S = 0x3B, // The length of time, in seconds, that a trust center will store a transient link key that a device can use to join its network. A transient key is added with a
    COULOMB_COUNTER_USAGE = 0x3C, // Cumulative energy usage metric since the last value reset of the coulomb counter plugin. Setting this value will reset the coulomb counter.
    MAX_BEACONS_TO_STORE = 0x3D, // When scanning, configure the maximum number of beacons to store in cache. Each beacon consumes one packet buffer in RAM.
    END_DEVICE_TIMEOUT_OPTIONS_MASK = 0x3E, // Set the mask to filter out unacceptable child timeout options on a router.
    END_DEVICE_KEEP_ALIVE_SUPPORT_MODE = 0x3F, // The end device keep-alive mode supported by the parent.
    ACTIVE_RADIO_CONFIG = 0x41, // Return the active radio config. Read only. Values are 0: Default, 1: Antenna Diversity, 2: Co-Existence, 3: Antenna diversity and Co-Existence.
    NWK_OPEN_DURATION = 0x42, // Return the number of seconds the network will remain open. A return value of 0 indicates that the network is closed. Read only.
    TRANSIENT_DEVICE_TIMEOUT = 0x43, // Timeout in milliseconds to store entries in the transient device table. If the devices are not authenticated before the timeout, the entry shall be purged
    KEY_STORAGE_VERSION = 0x44, // Return information about the key storage on an NCP. Returns 0 if keys are in classic key storage, and 1 if they are located in PSA key storage. Read only.
    DELAYED_JOIN_ACTIVATION = 0x45, // Return activation state about TC Delayed Join on an NCP. A return value of 0 indicates that the feature is not activated.
}

// Identifies a value based on specified characteristics. Each set of characteristics is unique to that value and is specified during the call to get the extended value.
enum EzspExtendedValueId : ubyte {
    ENDPOINT_FLAGS = 0x00, // The flags field associated with the specified endpoint.
    LAST_LEAVE_REASON = 0x01, // This is the reason for the node to leave the network as well as the device that told it to leave. The leave reason is the 1st byte of the value while the node ID is the 2nd and 3rd byte. If the leave was caused due to an API call rather than an over the air message, the node ID will be EMBER_UNKNOWN_NODE_ID (0xFFFD).
    GET_SOURCE_ROUTE_OVERHEAD = 0x02, // This number of bytes of overhead required in the network frame for source routing to a particular destination.
}

// Flags associated with the endpoint data configured on the NCP.
enum EzspEndpointFlags : ushort {
    DISABLED = 0x00, // Indicates that the endpoint is disabled and NOT discoverable via ZDO.
    ENABLED = 0x01, // Indicates that the endpoint is enabled and discoverable via ZDO.
}

// Values for EZSP_CONFIG_TX_POWER_MODE.
enum EmberConfigTxPowerMode : ushort {
    DEFAULT = 0x00, // Normal power mode and bi-directional RF transmitter output.
    BOOST = 0x01, // Enable boost power mode. This is a high-performance radio mode which offers increased receive sensitivity and transmit power at the cost of an increase in power consumption.
    ALTERNATE = 0x02, // Enable the alternate transmitter output. This allows for simplified connection to an external power amplifier via the RF_TX_ALT_P and RF_TX_ALT_N pins.
    BOOST_AND_ALTERNATE = 0x03, // Enable both boost mode and the alternate transmitter output.
}

// Identifies a policy.
enum EzspPolicyId : ubyte {
    TRUST_CENTER = 0x00, // Controls trust center behavior.
    BINDING_MODIFICATION = 0x01, // Controls how external binding modification requests are handled.
    UNICAST_REPLIES = 0x02, // Controls whether the Host supplies unicast replies.
    POLL_HANDLER = 0x03, // Controls whether pollHandler callbacks are generated.
    MESSAGE_CONTENTS_IN_CALLBACK = 0x04, // Controls whether the message contents are included in the messageSentHandler callback.
    TC_KEY_REQUEST = 0x05, // Controls whether the Trust Center will respond to Trust Center link key requests.
    APP_KEY_REQUEST = 0x06, // Controls whether the Trust Center will respond to application link key requests.
    PACKET_VALIDATE_LIBRARY = 0x07, // Controls whether ZigBee packets that appear invalid are automatically dropped by the stack. A counter will be incremented when this occurs.
    ZLL = 0x08, // Controls whether the stack will process ZLL messages.
    TC_REJOINS_USING_WELL_KNOWN_KEY = 0x09, // Controls whether Trust Center (insecure) rejoins for devices using the well-known link key are accepted. If rejoining using the well-known key is allowed, it is disabled again after sli_zigbee_allow_tc_rejoins_using_well_known_key_timeout_sec seconds.
}

// This is the policy decision bitmask that controls the trust center decision strategies. The bitmask is modified and extracted from the EzspDecisionId for supporting bitmask operations.
enum EzspDecisionBitmask : ushort {
    DEFAULT_CONFIGURATION = 0x0000, // Disallow joins and rejoins.
    ALLOW_JOINS = 0x0001, // Send the network key to all joining devices.
    ALLOW_UNSECURED_REJOINS = 0x0002, // Send the network key to all rejoining devices.
    SEND_KEY_IN_CLEAR = 0x0004, // Send the network key in the clear.
    IGNORE_UNSECURED_REJOINS = 0x0008, // Do nothing for unsecured rejoins.
    JOINS_USE_INSTALL_CODE_KEY = 0x0010, // Allow joins if there is an entry in the transient key table.
    DEFER_JOINS = 0x0020, // Delay sending the network key to a new joining device.
}

// Identifies a policy decision.
enum EzspDecisionId : ubyte {
    DEFER_JOINS_REJOINS_HAVE_LINK_KEY = 0x07, // Delay sending the network key to a new joining device.
    DISALLOW_BINDING_MODIFICATION = 0x10, // EZSP_BINDING_MODIFICATION_POLICY default decision. Do not allow the local binding table to be changed by remote nodes.
    ALLOW_BINDING_MODIFICATION = 0x11, // EZSP_BINDING_MODIFICATION_POLICY decision. Allow remote nodes to change the local binding table.
    CHECK_BINDING_MODIFICATIONS_ARE_VALID_ENDPOINT_CLUSTERS = 0x12, // EZSP_BINDING_MODIFICATION_POLICY decision. Allows remote nodes to set local binding entries only if the entries correspond to endpoints defined on the device, and for output clusters bound to those endpoints.
    HOST_WILL_NOT_SUPPLY_REPLY = 0x20, // EZSP_UNICAST_REPLIES_POLICY default decision. The NCP will automatically send an empty reply (containing no payload) for every unicast received.
    HOST_WILL_SUPPLY_REPLY = 0x21, // EZSP_UNICAST_REPLIES_POLICY decision. The NCP will only send a reply if it receives a sendReply command from the Host.
    POLL_HANDLER_IGNORE = 0x30, // EZSP_POLL_HANDLER_POLICY default decision. Do not inform the Host when a child polls.
    POLL_HANDLER_CALLBACK = 0x31, // EZSP_POLL_HANDLER_POLICY decision. Generate a pollHandler callback when a child polls.
    MESSAGE_TAG_ONLY_IN_CALLBACK = 0x40, // EZSP_MESSAGE_CONTENTS_IN_CALLBACK_POLICY default decision. Include only the message tag in the messageSentHandler callback.
    MESSAGE_TAG_AND_CONTENTS_IN_CALLBACK = 0x41, // EZSP_MESSAGE_CONTENTS_IN_CALLBACK_POLICY decision. Include both the message tag and the message contents in the messageSentHandler callback.
    DENY_TC_KEY_REQUESTS = 0x50, // EZSP_TC_KEY_REQUEST_POLICY decision. When the Trust Center receives a request for a Trust Center link key, it will be ignored.
    ALLOW_TC_KEY_REQUESTS_AND_SEND_CURRENT_KEY = 0x51, // EZSP_TC_KEY_REQUEST_POLICY decision. When the Trust Center receives a request for a Trust Center link key, it will reply to it with the corresponding key.
    ALLOW_TC_KEY_REQUEST_AND_GENERATE_NEW_KEY = 0x52, // EZSP_TC_KEY_REQUEST_POLICY decision. When the Trust Center receives a request for a Trust Center link key, it will generate a key to send to the joiner. After generation, the key will be added to the transient key table and after verification this key will be added to the link key table.
    DENY_APP_KEY_REQUESTS = 0x60, // EZSP_APP_KEY_REQUEST_POLICY decision. When the Trust Center receives a request for an application link key, it will be ignored.
    ALLOW_APP_KEY_REQUESTS = 0x61, // EZSP_APP_KEY_REQUEST_POLICY decision. When the Trust Center receives a request for an application link key, it will randomly generate a key and send it to both partners.
    PACKET_VALIDATE_LIBRARY_CHECKS_ENABLED = 0x62, // Indicates that packet validate library checks are enabled on the NCP.
    PACKET_VALIDATE_LIBRARY_CHECKS_DISABLED = 0x63, // Indicates that packet validate library checks are NOT enabled on the NCP.
}

// Manufacturing token IDs used by ezspGetMfgToken().
enum EzspMfgTokenId : ubyte {
    CUSTOM_VERSION = 0x00, // Custom version (2 bytes).
    MFG_STRING = 0x01, // Manufacturing string (16 bytes).
    BOARD_NAME = 0x02, // Board name (16 bytes).
    MANUF_ID = 0x03, // Manufacturing ID (2 bytes).
    PHY_CONFIG = 0x04, // Radio configuration (2 bytes).
    BOOTLOAD_AES_KEY = 0x05, // Bootload AES key (16 bytes).
    ASH_CONFIG = 0x06, // ASH configuration (40 bytes).
    EZSP_STORAGE = 0x07, // EZSP storage (8 bytes).
    STACK_CAL_DATA = 0x08, // Radio calibration data (64 bytes). 4 bytes are stored for each of the 16 channels. This token is not stored in the Flash Information Area. It is updated by the stack each time a calibration is performed.
    MFG_CBKE_DATA = 0x09, // Certificate Based Key Exchange (CBKE) data (92 bytes).
    INSTALLATION_CODE = 0x0A, // Installation code (20 bytes).
    STACK_CAL_FILTER = 0x0B, // Radio channel filter calibration data (1 byte). This token is not stored in the Flash Information Area. It is updated by the stack each time a calibration is performed.
    CUSTOM_EUI_64 = 0x0C, // Custom EUI64 MAC address (8 bytes).
    CTUNE = 0x0D, // CTUNE value (2 byte).
}

// Status values used by EZSP.
enum EzspStatus : ubyte {
    SUCCESS = 0x00, // Success.
    SPI_ERR_FATAL = 0x10, // Fatal error.
    SPI_ERR_NCP_RESET = 0x11, // The Response frame of the current transaction indicates the NCP has reset.
    SPI_ERR_OVERSIZED_EZSP_FRAME = 0x12, // The NCP is reporting that the Command frame of the current transaction is oversized (the length byte is too large).
    SPI_ERR_ABORTED_TRANSACTION = 0x13, // The Response frame of the current transaction indicates the previous transaction was aborted (nSSEL deasserted too soon).
    SPI_ERR_MISSING_FRAME_TERMINATOR = 0x14, // The Response frame of the current transaction indicates the frame terminator is missing from the Command frame.
    SPI_ERR_WAIT_SECTION_TIMEOUT = 0x15, // The NCP has not provided a Response within the time limit defined by WAIT_SECTION_TIMEOUT.
    SPI_ERR_NO_FRAME_TERMINATOR = 0x16, // The Response frame from the NCP is missing the frame terminator.
    SPI_ERR_EZSP_COMMAND_OVERSIZED = 0x17, // The Host attempted to send an oversized Command (the length byte is too large) and the AVR's spi-protocol.c blocked the transmission.
    SPI_ERR_EZSP_RESPONSE_OVERSIZED = 0x18, // The NCP attempted to send an oversized Response (the length byte is too large) and the AVR's spi-protocol.c blocked the reception.
    SPI_WAITING_FOR_RESPONSE = 0x19, // The Host has sent the Command and is still waiting for the NCP to send a Response.
    SPI_ERR_HANDSHAKE_TIMEOUT = 0x1A, // The NCP has not asserted nHOST_INT within the time limit defined by WAKE_HANDSHAKE_TIMEOUT.
    SPI_ERR_STARTUP_TIMEOUT = 0x1B, // The NCP has not asserted nHOST_INT after an NCP reset within the time limit defined by STARTUP_TIMEOUT.
    SPI_ERR_STARTUP_FAIL = 0x1C, // The Host attempted to verify the SPI Protocol activity and version number, and the verification failed.
    SPI_ERR_UNSUPPORTED_SPI_COMMAND = 0x1D, // The Host has sent a command with a SPI Byte that is unsupported by the current mode the NCP is operating in.
    ASH_IN_PROGRESS = 0x20, // Operation not yet complete.
    HOST_FATAL_ERROR = 0x21, // Fatal error detected by host.
    ASH_NCP_FATAL_ERROR = 0x22, // Fatal error detected by NCP.
    DATA_FRAME_TOO_LONG = 0x23, // Tried to send DATA frame too long.
    DATA_FRAME_TOO_SHORT = 0x24, // Tried to send DATA frame too short.
    NO_TX_SPACE = 0x25, // No space for tx'ed DATA frame.
    NO_RX_SPACE = 0x26, // No space for rec'd DATA frame.
    NO_RX_DATA = 0x27, // No receive data available.
    NOT_CONNECTED = 0x28, // Not in Connected state.
    ERROR_VERSION_NOT_SET = 0x30, // The NCP received a command before the EZSP version had been set.
    ERROR_INVALID_FRAME_ID = 0x31, // The NCP received a command containing an unsupported frame ID.
    ERROR_WRONG_DIRECTION = 0x32, // The direction flag in the frame control field was incorrect.
    ERROR_TRUNCATED = 0x33, // The truncated flag in the frame control field was set, indicating there was not enough memory available to complete the response or that the response would have exceeded the maximum EZSP frame length.
    ERROR_OVERFLOW = 0x34, // The overflow flag in the frame control field was set, indicating one or more callbacks occurred since the previous response and there was not enough memory available to report them to the Host.
    ERROR_OUT_OF_MEMORY = 0x35, // Insufficient memory was available.
    ERROR_INVALID_VALUE = 0x36, // The value was out of bounds.
    ERROR_INVALID_ID = 0x37, // The configuration id was not recognized.
    ERROR_INVALID_CALL = 0x38, // Configuration values can no longer be modified.
    ERROR_NO_RESPONSE = 0x39, // The NCP failed to respond to a command.
    ERROR_COMMAND_TOO_LONG = 0x40, // The length of the command exceeded the maximum EZSP frame length.
    ERROR_QUEUE_FULL = 0x41, // The UART receive queue was full causing a callback response to be dropped.
    ERROR_COMMAND_FILTERED = 0x42, // The command has been filtered out by NCP.
    ERROR_SECURITY_KEY_ALREADY_SET = 0x43, // EZSP Security Key is already set
    ERROR_SECURITY_TYPE_INVALID = 0x44, // EZSP Security Type is invalid
    ERROR_SECURITY_PARAMETERS_INVALID = 0x45, // EZSP Security Parameters are invalid
    ERROR_SECURITY_PARAMETERS_ALREADY_SET = 0x46, // EZSP Security Parameters are already set
    ERROR_SECURITY_KEY_NOT_SET = 0x47, // EZSP Security Key is not set
    ERROR_SECURITY_PARAMETERS_NOT_SET = 0x48, // EZSP Security Parameters are not set
    ERROR_UNSUPPORTED_CONTROL = 0x49, // Received frame with unsupported control byte
    ERROR_UNSECURE_FRAME = 0x4A, // Received frame is unsecure, when security is established
    ASH_ERROR_VERSION = 0x50, // Incompatible ASH version
    ASH_ERROR_TIMEOUTS = 0x51, // Exceeded max ACK timeouts
    ASH_ERROR_RESET_FAIL = 0x52, // Timed out waiting for RSTACK
    ASH_ERROR_NCP_RESET = 0x53, // Unexpected ncp reset
    ERROR_SERIAL_INIT = 0x54, // Serial port initialization failed
    ASH_ERROR_NCP_TYPE = 0x55, // Invalid ncp processor type
    ASH_ERROR_RESET_METHOD = 0x56, // Invalid ncp reset method
    ASH_ERROR_XON_XOFF = 0x57, // XON/XOFF not supported by host driver
    ASH_STARTED = 0x70, // ASH protocol started
    ASH_CONNECTED = 0x71, // ASH protocol connected
    ASH_DISCONNECTED = 0x72, // ASH protocol disconnected
    ASH_ACK_TIMEOUT = 0x73, // Timer expired waiting for ack
    ASH_CANCELLED = 0x74, // Frame in progress cancelled
    ASH_OUT_OF_SEQUENCE = 0x75, // Received frame out of sequence
    ASH_BAD_CRC = 0x76, // Received frame with CRC error
    ASH_COMM_ERROR = 0x77, // Received frame with comm error
    ASH_BAD_ACKNUM = 0x78, // Received frame with bad ackNum
    ASH_TOO_SHORT = 0x79, // Received frame shorter than minimum
    ASH_TOO_LONG = 0x7A, // Received frame longer than maximum
    ASH_BAD_CONTROL = 0x7B, // Received frame with illegal control byte
    ASH_BAD_LENGTH = 0x7C, // Received frame with illegal length for its type
    ASH_ACK_RECEIVED = 0x7D, // Received ASH Ack
    ASH_ACK_SENT = 0x7E, // Sent ASH Ack
    ASH_NAK_RECEIVED = 0x7F, // Received ASH Nak
    ASH_NAK_SENT = 0x80, // Sent ASH Nak
    ASH_RST_RECEIVED = 0x81, // Received ASH RST
    ASH_RST_SENT = 0x82, // Sent ASH RST
    ASH_STATUS = 0x83, // ASH Status
    ASH_TX = 0x84, // ASH TX
    ASH_RX = 0x85, // ASH RX
    CPC_ERROR_INIT = 0x86, // Failed to connect to CPC daemon or failed to open CPC endpoint
    NO_ERROR = 0xFF, // No reset or error
}

// Return type from stack functions.
enum EmberStatus : ubyte {
    SUCCESS = 0x00, // The generic 'no error' message.
    ERR_FATAL = 0x01, // The generic 'fatal error' message.
    BAD_ARGUMENT = 0x02, // An invalid value was passed as an argument to a function
    EEPROM_MFG_STACK_VERSION_MISMATCH = 0x04, // The manufacturing and stack token format in non-volatile memory is different than what the stack expects (returned at initialization).
    EEPROM_MFG_VERSION_MISMATCH = 0x06, // The manufacturing token format in non-volatile memory is different than what the stack expects (returned at initialization).
    EEPROM_STACK_VERSION_MISMATCH = 0x07, // The stack token format in non-volatile memory is different than what the stack expects (returned at initialization).
    NO_BUFFERS = 0x18, // There are no more buffers.
    SERIAL_INVALID_BAUD_RATE = 0x20, // Specified an invalid baud rate.
    SERIAL_INVALID_PORT = 0x21, // Specified an invalid serial port.
    SERIAL_TX_OVERFLOW = 0x22, // Tried to send too much data.
    SERIAL_RX_OVERFLOW = 0x23, // There was not enough space to store a received character and the character was dropped.
    SERIAL_RX_FRAME_ERROR = 0x24, // Detected a UART framing error.
    SERIAL_RX_PARITY_ERROR = 0x25, // Detected a UART parity error.
    SERIAL_RX_EMPTY = 0x26, // There is no received data to process.
    SERIAL_RX_OVERRUN_ERROR = 0x27, // The receive interrupt was not handled in time, and a character was dropped.
    MAC_TRANSMIT_QUEUE_FULL = 0x39, // The MAC transmit queue is full.
    MAC_UNKNOWN_HEADER_TYPE = 0x3A, // MAC header FCR error on receive.
    MAC_SCANNING = 0x3D, // The MAC can't complete this task because it is scanning.
    MAC_NO_DATA = 0x31, // No pending data exists for device doing a data poll.
    MAC_JOINED_NETWORK = 0x32, // Attempt to scan when we are joined to a network.
    MAC_BAD_SCAN_DURATION = 0x33, // Scan duration must be 0 to 14 inclusive. Attempt was made to scan with an incorrect duration value.
    MAC_INCORRECT_SCAN_TYPE = 0x34, // emberStartScan was called with an incorrect scan type.
    MAC_INVALID_CHANNEL_MASK = 0x35, // emberStartScan was called with an invalid channel mask.
    MAC_COMMAND_TRANSMIT_FAILURE = 0x36, // Failed to scan current channel because we were unable to transmit the relevant MAC command.
    MAC_NO_ACK_RECEIVED = 0x40, // We expected to receive an ACK following the transmission, but the MAC level ACK was never received.
    MAC_INDIRECT_TIMEOUT = 0x42, // Indirect data message timed out before polled.
    SIM_EEPROM_ERASE_PAGE_GREEN = 0x43, // The Simulated EEPROM is telling the application that there is at least one flash page to be erased. The GREEN status means the current page has not filled above the ERASE_CRITICAL_THRESHOLD. The application should call the function halSimEepromErasePage when it can to erase a page.
    SIM_EEPROM_ERASE_PAGE_RED = 0x44, // The Simulated EEPROM is telling the application that there is at least one flash page to be erased. The RED status means the current page has filled above the ERASE_CRITICAL_THRESHOLD. Due to the shrinking availability of write space, there is a danger of data loss. The application must call the function halSimEepromErasePage as soon as possible to erase a page.
    SIM_EEPROM_FULL = 0x45, // The Simulated EEPROM has run out of room to write any new data and the data trying to be set has been lost. This error code is the result of ignoring the SIM_EEPROM_ERASE_PAGE_RED error code. The application must call the function halSimEepromErasePage to make room for any further calls to set a token.
    ERR_FLASH_WRITE_INHIBITED = 0x46, // A fatal error has occurred while trying to write data to the Flash. The target memory attempting to be programmed is already programmed. The flash write routines were asked to flip a bit from a 0 to 1, which is physically impossible and the write was therefore inhibited. The data in the flash cannot be trusted after this error.
    ERR_FLASH_VERIFY_FAILED = 0x47, // A fatal error has occurred while trying to write data to the Flash and the write verification has failed. The data in the flash cannot be trusted after this error, and it is possible this error is the result of exceeding the life cycles of the flash.
    SIM_EEPROM_INIT_1_FAILED = 0x48, // Attempt 1 to initialize the Simulated EEPROM has failed. This failure means the information already stored in Flash (or a lack thereof), is fatally incompatible with the token information compiled into the code image being run.
    SIM_EEPROM_INIT_2_FAILED = 0x49, // Attempt 2 to initialize the Simulated EEPROM has failed. This failure means Attempt 1 failed, and the token system failed to properly reload default tokens and reset the Simulated EEPROM.
    SIM_EEPROM_INIT_3_FAILED = 0x4A, // Attempt 3 to initialize the Simulated EEPROM has failed. This failure means one or both of the tokens TOKEN_MFG_NVDATA_VERSION or TOKEN_STACK_NVDATA_VERSION were incorrect and the token system failed to properly reload default tokens and reset the Simulated EEPROM.
    ERR_FLASH_PROG_FAIL = 0x4B, // A fatal error has occurred while trying to write data to the flash, possibly due to write protection or an invalid address. The data in the flash cannot be trusted after this error, and it is possible this error is the result of exceeding the life cycles of the flash.
    ERR_FLASH_ERASE_FAIL = 0x4C, // A fatal error has occurred while trying to erase flash, possibly due to write protection. The data in the flash cannot be trusted after this error, and it is possible this error is the result of exceeding the life cycles of the flash.
    ERR_BOOTLOADER_TRAP_TABLE_BAD = 0x58, // The bootloader received an invalid message (failed attempt to go into bootloader).
    ERR_BOOTLOADER_TRAP_UNKNOWN = 0x59, // Bootloader received an invalid message (failed attempt to go into bootloader).
    ERR_BOOTLOADER_NO_IMAGE = 0x5A, // The bootloader cannot complete the bootload operation because either an image was not found or the image exceeded memory bounds.
    DELIVERY_FAILED = 0x66, // The APS layer attempted to send or deliver a message, but it failed.
    BINDING_INDEX_OUT_OF_RANGE = 0x69, // This binding index is out of range of the current binding table.
    ADDRESS_TABLE_INDEX_OUT_OF_RANGE = 0x6A, // This address table index is out of range for the current address table.
    INVALID_BINDING_INDEX = 0x6C, // An invalid binding table index was given to a function.
    INVALID_CALL = 0x70, // The API call is not allowed given the current state of the stack.
    COST_NOT_KNOWN = 0x71, // The link cost to a node is not known.
    MAX_MESSAGE_LIMIT_REACHED = 0x72, // The maximum number of in-flight messages (i.e. EMBER_APS_UNICAST_MESSAGE_COUNT) has been reached.
    MESSAGE_TOO_LONG = 0x74, // The message to be transmitted is too big to fit into a single over-the-air packet.
    BINDING_IS_ACTIVE = 0x75, // The application is trying to delete or overwrite a binding that is in use.
    ADDRESS_TABLE_ENTRY_IS_ACTIVE = 0x76, // The application is trying to overwrite an address table entry that is in use.
    ADC_CONVERSION_DONE = 0x80, // Conversion is complete.
    ADC_CONVERSION_BUSY = 0x81, // Conversion cannot be done because a request is being processed.
    ADC_CONVERSION_DEFERRED = 0x82, // Conversion is deferred until the current request has been processed.
    ADC_NO_CONVERSION_PENDING = 0x84, // No results are pending.
    SLEEP_INTERRUPTED = 0x85, // Sleeping (for a duration) has been abnormally interrupted and exited prematurely.
    PHY_TX_UNDERFLOW = 0x88, // The transmit hardware buffer underflowed.
    PHY_TX_INCOMPLETE = 0x89, // The transmit hardware did not finish transmitting a packet.
    PHY_INVALID_CHANNEL = 0x8A, // An unsupported channel setting was specified.
    PHY_INVALID_POWER = 0x8B, // An unsupported power setting was specified.
    PHY_TX_BUSY = 0x8C, // The packet cannot be transmitted because the physical MAC layer is currently transmitting a packet. (This is used for the MAC backoff algorithm.)
    PHY_TX_CCA_FAIL = 0x8D, // The transmit attempt failed because all CCA attempts indicated that the channel was busy.
    PHY_OSCILLATOR_CHECK_FAILED = 0x8E, // The software installed on the hardware doesn't recognize the hardware radio type.
    PHY_ACK_RECEIVED = 0x8F, // The expected ACK was received after the last transmission.
    NETWORK_UP = 0x90, // The stack software has completed initialization and is ready to send and receive packets over the air.
    NETWORK_DOWN = 0x91, // The network is not operating.
    JOIN_FAILED = 0x94, // An attempt to join a network failed.
    MOVE_FAILED = 0x96, // After moving, a mobile node's attempt to re-establish contact with the network failed.
    CANNOT_JOIN_AS_ROUTER = 0x98, // An attempt to join as a router failed due to a ZigBee versus ZigBee Pro incompatibility. ZigBee devices joining ZigBee Pro networks (or vice versa) must join as End Devices, not Routers.
    NODE_ID_CHANGED = 0x99, // The local node ID has changed. The application can obtain the new node ID by calling emberGetNodeId().
    PAN_ID_CHANGED = 0x9A, // The local PAN ID has changed. The application can obtain the new PAN ID by calling emberGetPanId().
    NETWORK_OPENED = 0x9C, // The network has been opened for joining.
    NETWORK_CLOSED = 0x9D, // The network has been closed for joining.
    NO_BEACONS = 0xAB, // An attempt to join or rejoin the network failed because no router beacons could be heard by the joining node.
    RECEIVED_KEY_IN_THE_CLEAR = 0xAC, // An attempt was made to join a Secured Network using a pre-configured key, but the Trust Center sent back a Network Key in-the-clear when an encrypted Network Key was required.
    NO_NETWORK_KEY_RECEIVED = 0xAD, // An attempt was made to join a Secured Network, but the device did not receive a Network Key.
    NO_LINK_KEY_RECEIVED = 0xAE, // After a device joined a Secured Network, a Link Key was requested but no response was ever received.
    PRECONFIGURED_KEY_REQUIRED = 0xAF, // An attempt was made to join a Secured Network without a pre-configured key, but the Trust Center sent encrypted data using a pre-configured key.
    NOT_JOINED = 0x93, // The node has not joined a network.
    INVALID_SECURITY_LEVEL = 0x95, // The chosen security level (the value of EMBER_SECURITY_LEVEL) is not supported by the stack.
    NETWORK_BUSY = 0xA1, // A message cannot be sent because the network is currently overloaded.
    INVALID_ENDPOINT = 0xA3, // The application tried to send a message using an endpoint that it has not defined.
    BINDING_HAS_CHANGED = 0xA4, // The application tried to use a binding that has been remotely modified and the change has not yet been reported to the application.
    INSUFFICIENT_RANDOM_DATA = 0xA5, // An attempt to generate random bytes failed because of insufficient random data from the radio.
    APS_ENCRYPTION_ERROR = 0xA6, // There was an error in trying to encrypt at the APS Level. This could result from either an inability to determine the long address of the recipient from the short address (no entry in the binding table) or there is no link key entry in the table associated with the destination, or there was a failure to load the correct key into the encryption core.
    SECURITY_STATE_NOT_SET = 0xA8, // There was an attempt to form or join a network with security without calling emberSetInitialSecurityState() first.
    KEY_TABLE_INVALID_ADDRESS = 0xB3, // There was an attempt to set an entry in the key table using an invalid long address. An entry cannot be set using either the local device's or Trust Center's IEEE address. Or an entry already exists in the table with the same IEEE address. An Address of all zeros or all F's are not valid addresses in 802.15.4.
    SECURITY_CONFIGURATION_INVALID = 0xB7, // There was an attempt to set a security configuration that is not valid given the other security settings.
    TOO_SOON_FOR_SWITCH_KEY = 0xB8, // There was an attempt to broadcast a key switch too quickly after broadcasting the next network key. The Trust Center must wait at least a period equal to the broadcast timeout so that all routers have a chance to receive the broadcast of the new network key.
    KEY_NOT_AUTHORIZED = 0xBB, // The message could not be sent because the link key corresponding to the destination is not authorized for use in APS data messages. APS Commands (sent by the stack) are allowed. To use it for encryption of APS data messages it must be authorized using a key agreement protocol (such as CBKE).
    SECURITY_DATA_INVALID = 0xBD, // The security data provided was not valid, or an integrity check failed.
    SOURCE_ROUTE_FAILURE = 0xA9, // A ZigBee route error command frame was received indicating that a source routed message from this node failed en route.
    MANY_TO_ONE_ROUTE_FAILURE = 0xAA, // A ZigBee route error command frame was received indicating that a message sent to this node along a many-to-one route failed en route. The route error frame was delivered by an ad-hoc search for a functioning route.
    STACK_AND_HARDWARE_MISMATCH = 0xB0, // A critical and fatal error indicating that the version of the stack trying to run does not match with the chip it is running on. The software (stack) on the chip must be replaced with software that is compatible with the chip.
    INDEX_OUT_OF_RANGE = 0xB1, // An index was passed into the function that was larger than the valid range.
    TABLE_FULL = 0xB4, // There are no empty entries left in the table.
    TABLE_ENTRY_ERASED = 0xB6, // The requested table entry has been erased and contains no valid data.
    LIBRARY_NOT_PRESENT = 0xB5, // The requested function cannot be executed because the library that contains the necessary functionality is not present.
    OPERATION_IN_PROGRESS = 0xBA, // The stack accepted the command and is currently processing the request. The results will be returned via an appropriate handler.
    APPLICATION_ERROR_0 = 0xF0, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_1 = 0xF1, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_2 = 0xF2, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_3 = 0xF3, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_4 = 0xF4, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_5 = 0xF5, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_6 = 0xF6, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_7 = 0xF7, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_8 = 0xF8, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_9 = 0xF9, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_10 = 0xFA, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_11 = 0xFB, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_12 = 0xFC, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_13 = 0xFD, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
    APPLICATION_ERROR_14 = 0xFE, // This error is reserved for customer application use. This will never be returned from any portion of the network stack or HAL.
}

// Either marks an event as inactive or specifies the units for the event execution time.
enum EmberEventUnits : ubyte {
    INACTIVE = 0x00, // The event is not scheduled to run.
    MS_TIME = 0x01, // The execution time is in approximate milliseconds.
    QS_TIME = 0x02, // The execution time is in 'binary' quarter seconds (256 approximate milliseconds each).
    MINUTE_TIME = 0x03, // The execution time is in 'binary' minutes (65536 approximate milliseconds each).
}

// The type of the node.
enum EmberNodeType : ubyte {
    UNKNOWN_DEVICE = 0x00, // Device is not joined.
    COORDINATOR = 0x01, // Will relay messages and can act as a parent to other nodes.
    ROUTER = 0x02, // Will relay messages and can act as a parent to other nodes.
    END_DEVICE = 0x03, // Communicates only with its parent and will not relay messages.
    SLEEPY_END_DEVICE = 0x04, // An end device whose radio can be turned off to save power. The application must poll to receive messages.
}

// The possible join states for a node.
enum EmberNetworkStatus : ubyte {
    NO_NETWORK = 0x00, // The node is not associated with a network in any way.
    JOINING_NETWORK = 0x01, // The node is currently attempting to join a network.
    JOINED_NETWORK = 0x02, // The node is joined to a network.
    JOINED_NETWORK_NO_PARENT = 0x03, // The node is an end device joined to a network but its parent is not responding.
    LEAVING_NETWORK = 0x04, // The node is in the process of leaving its current network.
}

// Incoming message types.
enum EmberIncomingMessageType : ubyte {
    UNICAST = 0x00, // Unicast.
    UNICAST_REPLY = 0x01, // Unicast reply.
    MULTICAST = 0x02, // Multicast.
    MULTICAST_LOOPBACK = 0x03, // Multicast sent by the local device.
    BROADCAST = 0x04, // Broadcast.
    BROADCAST_LOOPBACK = 0x05, // Broadcast sent by the local device.
    MANY_TO_ONE_ROUTE_REQUEST = 0x06, // Many to one route request.
}

// Outgoing message types.
enum EmberOutgoingMessageType : ubyte {
    DIRECT = 0x00, // Unicast sent directly to an EmberNodeId.
    VIA_ADDRESS_TABLE = 0x01, // Unicast sent using an entry in the address table.
    VIA_BINDING = 0x02, // Unicast sent using an entry in the binding table.
    MULTICAST = 0x03, // Multicast message. This value is passed to emberMessageSentHandler() only. It may not be passed to emberSendUnicast().
    BROADCAST = 0x04, // Broadcast message. This value is passed to emberMessageSentHandler() only. It may not be passed to emberSendUnicast().
}

// MAC passthrough message type flags.
enum EmberMacPassthroughType : ubyte {
    NONE = 0x00, // No MAC passthrough messages.
    SE_INTERPAN = 0x01, // SE InterPAN messages.
    EMBERNET = 0x02, // Legacy EmberNet messages.
    EMBERNET_SOURCE = 0x04, // Legacy EmberNet messages filtered by their source address.
}

// Binding types.
enum EmberBindingType : ubyte {
    UNUSED_BINDING = 0x00, // A binding that is currently not in use.
    UNICAST_BINDING = 0x01, // A unicast binding whose 64-bit identifier is the destination EUI64.
    MANY_TO_ONE_BINDING = 0x02, // A unicast binding whose 64-bit identifier is the aggregator EUI64.
    MULTICAST_BINDING = 0x03, // A multicast binding whose 64-bit identifier is the group address. A multicast binding can be used to send messages to the group and to receive messages sent to the group.
}

// Options to use when sending a message.
enum EmberApsOption : ushort {
    NONE = 0x0000, // No options.
    ENCRYPTION = 0x0020, // Send the message using APS Encryption, using the Link Key shared with the destination node to encrypt the data at the APS Level.
    RETRY = 0x0040, // Resend the message using the APS retry mechanism.
    ENABLE_ROUTE_DISCOVERY = 0x0100, // Causes a route discovery to be initiated if no route to the destination is known.
    FORCE_ROUTE_DISCOVERY = 0x0200, // Causes a route discovery to be initiated even if one is known.
    SOURCE_EUI64 = 0x0400, // Include the source EUI64 in the network frame.
    DESTINATION_EUI64 = 0x0800, // Include the destination EUI64 in the network frame.
    ENABLE_ADDRESS_DISCOVERY = 0x1000, // Send a ZDO request to discover the node ID of the destination, if it is not already know.
    POLL_RESPONSE = 0x2000, // Reserved.
    ZDO_RESPONSE_REQUIRED = 0x4000, // This incoming message is a ZDO request not handled by the EmberZNet stack, and the application is responsible for sending a ZDO response. This flag is used only when the ZDO is configured to have requests handled by the application. See the EZSP_CONFIG_APPLICATION_ZDO_FLAGS configuration parameter for more information.
    FRAGMENT = 0x8000, // This message is part of a fragmented message. This option may only be set for unicasts. The groupId field gives the index of this fragment in the low-order byte. If the low-order byte is zero this is the first fragment and the high-order byte contains the number of fragments in the message.
}

// Network scan types.
enum EzspNetworkScanType : ubyte {
    ENERGY_SCAN = 0x00, // An energy scan scans each channel for its RSSI value.
    ACTIVE_SCAN = 0x01, // An active scan scans each channel for available networks.
}

// Decision made by the trust center when a node attempts to join.
enum EmberJoinDecision : ubyte {
    ALLOW_JOIN = 0x00, // Allow the node to join.
    ALLOW_JOIN_NO_SUCH_NETWORK = 0x01, // Allow the node to join, but the network ID is not recognized.
    DENY_JOIN = 0x02, // Deny join.
    NO_ACTION = 0x03, // Take no action.
}

// This is the Initial Security Bitmask that controls the use of various security features.
enum EmberInitialSecurityBitmask : ushort {
    STANDARD_SECURITY_MODE = 0x0000, // This enables ZigBee Standard Security on the node.
    DISTRIBUTED_TRUST_CENTER_MODE = 0x0002, // This enables Distributed Trust Center Mode for the device forming the network. (Previously known as EMBER_NO_TRUST_CENTER_MODE)
    TRUST_CENTER_GLOBAL_LINK_KEY = 0x0004, // This enables a Global Link Key for the Trust Center. All nodes will share the same Trust Center Link Key.
    PRECONFIGURED_NETWORK_KEY_MODE = 0x0008, // This enables devices that perform MAC Association with a pre-configured Network Key to join the network. It is only set on the Trust Center.
    TRUST_CENTER_USES_HASHED_LINK_KEY = 0x0084, // This denotes that the preconfiguredKey is not the actual Link Key but a Secret Key known only to the Trust Center. It is hashed with the IEEE Address of the destination device in order to create the actual Link Key used in encryption. This is bit is only used by the Trust Center. The joining device need not set this.
    HAVE_PRECONFIGURED_KEY = 0x0100, // This denotes that the preconfiguredKey element has valid data that should be used to configure the initial security state.
    HAVE_NETWORK_KEY = 0x0200, // This denotes that the networkKey element has valid data that should be used to configure the initial security state.
    GET_LINK_KEY_WHEN_JOINING = 0x0400, // This denotes to a joining node that it should attempt to acquire a Trust Center Link Key during joining. This is only necessary if the device does not have a pre-configured key.
    REQUIRE_ENCRYPTED_KEY = 0x0800, // This denotes that a joining device should only accept an encrypted network key from the Trust Center (using its pre-configured key). A key sent in-the-clear by the Trust Center will be rejected and the join will fail. This option is only valid when utilizing a pre-configured key.
    NO_FRAME_COUNTER_RESET = 0x1000, // This denotes whether the device should NOT reset its outgoing frame counters (both NWK and APS) when emberSetInitialSecurityState() is called. Normally it is advised to reset the frame counter before joining a new network. However in cases where a device is joining to the same network again (but not using emberRejoinNetwork()) it should keep the NWK and APS frame counters stored in its tokens.
    GET_PRECONFIGURED_KEY_FROM_INSTALL_CODE = 0x2000, // This denotes that the device should obtain its preconfigured key from an installation code stored in the manufacturing token. The token contains a value that will be hashed to obtain the actual preconfigured key. If that token is not valid, then the call to emberSetInitialSecurityState() will fail.
    HAVE_TRUST_CENTER_EUI64 = 0x0040, // This denotes that the EmberInitialSecurityState::preconfiguredTrustCenterEui64 has a value in it containing the trust center EUI64. The device will only join a network and accept commands from a trust center with that EUI64. Normally this bit is NOT set, and the EUI64 of the trust center is learned during the join process. When commissioning a device to join onto an existing network, which is using a trust center, and without sending any messages, this bit must be set and the field EmberInitialSecurityState::preconfiguredTrustCenterEui64 must be populated with the appropriate EUI64.
}

// This is the Current Security Bitmask that details the use of various security features.
enum EmberCurrentSecurityBitmask : ushort {
    STANDARD_SECURITY_MODE = 0x0000, // This denotes that the device is running in a network with ZigBee Standard Security.
    DISTRIBUTED_TRUST_CENTER_MODE = 0x0002, // This denotes that the device is running in a network without a centralized Trust Center.
    GLOBAL_LINK_KEY = 0x0004, // This denotes that the device has a Global Link Key. The Trust Center Link Key is the same across multiple nodes.
    HAVE_TRUST_CENTER_LINK_KEY = 0x0010, // This denotes that the node has a Trust Center Link Key.
    TRUST_CENTER_USES_HASHED_LINK_KEY = 0x0084, // This denotes that the Trust Center is using a Hashed Link Key.
}

// Describes the type of ZigBee security key.
enum EmberKeyType : ubyte {
    TRUST_CENTER_LINK_KEY = 0x01, // A shared key between the Trust Center and a device.
    CURRENT_NETWORK_KEY = 0x03, // The current active Network Key used by all devices in the network.
    NEXT_NETWORK_KEY = 0x04, // The alternate Network Key that was previously in use, or the newer key that will be switched to.
    APPLICATION_LINK_KEY = 0x05, // An Application Link Key shared with another (non-Trust Center) device.
}

// Describes the presence of valid data within the EmberKeyStruct structure.
enum EmberKeyStructBitmask : ushort {
    HAS_SEQUENCE_NUMBER = 0x0001, // The key has a sequence number associated with it.
    HAS_OUTGOING_FRAME_COUNTER = 0x0002, // The key has an outgoing frame counter associated with it.
    HAS_INCOMING_FRAME_COUNTER = 0x0004, // The key has an incoming frame counter associated with it.
    HAS_PARTNER_EUI64 = 0x0008, // The key has a Partner IEEE address associated with it.
}

// The status of the device update.
enum EmberDeviceUpdate : ubyte {
    STANDARD_SECURITY_SECURED_REJOIN = 0x0,
    STANDARD_SECURITY_UNSECURED_JOIN = 0x1,
    DEVICE_LEFT = 0x2,
    STANDARD_SECURITY_UNSECURED_REJOIN = 0x3,
}

// The status of the attempt to establish a key.
enum EmberKeyStatus : ubyte {
    APP_LINK_KEY_ESTABLISHED = 0x01,
    TRUST_CENTER_LINK_KEY_ESTABLISHED = 0x03,
    KEY_ESTABLISHMENT_TIMEOUT = 0x04,
    KEY_TABLE_FULL = 0x05,
    TC_RESPONDED_TO_KEY_REQUEST = 0x06,
    TC_APP_KEY_SENT_TO_REQUESTER = 0x07,
    TC_RESPONSE_TO_KEY_REQUEST_FAILED = 0x08,
    TC_REQUEST_KEY_TYPE_NOT_SUPPORTED = 0x09,
    TC_NO_LINK_KEY_FOR_REQUESTER = 0x0A,
    TC_REQUESTER_EUI64_UNKNOWN = 0x0B,
    TC_RECEIVED_FIRST_APP_KEY_REQUEST = 0x0C,
    TC_TIMEOUT_WAITING_FOR_SECOND_APP_KEY_REQUEST = 0x0D,
    TC_NON_MATCHING_APP_KEY_REQUEST_RECEIVED = 0x0E,
    TC_FAILED_TO_SEND_APP_KEYS = 0x0F,
    TC_FAILED_TO_STORE_APP_KEY_REQUEST = 0x10,
    TC_REJECTED_APP_KEY_REQUEST = 0x11,
}

// Defines the events reported to the application.
enum EmberCounterType : ubyte {
    MAC_RX_BROADCAST = 0, // The MAC received a broadcast.
    MAC_TX_BROADCAST = 1, // The MAC transmitted a broadcast.
    MAC_RX_UNICAST = 2, // The MAC received a unicast.
    MAC_TX_UNICAST_SUCCESS = 3, // The MAC successfully transmitted a unicast.
    MAC_TX_UNICAST_RETRY = 4, // The MAC retried a unicast.
    MAC_TX_UNICAST_FAILED = 5, // The MAC unsuccessfully transmitted a unicast.
    APS_DATA_RX_BROADCAST = 6, // The APS layer received a data broadcast.
    APS_DATA_TX_BROADCAST = 7, // The APS layer transmitted a data broadcast.
    APS_DATA_RX_UNICAST = 8, // The APS layer received a data unicast.
    APS_DATA_TX_UNICAST_SUCCESS = 9, // The APS layer successfully transmitted a data unicast.
    APS_DATA_TX_UNICAST_RETRY = 10, // The APS layer retried a data unicast.
    APS_DATA_TX_UNICAST_FAILED = 11, // The APS layer unsuccessfully transmitted a data unicast.
    ROUTE_DISCOVERY_INITIATED = 12, // The network layer successfully submitted a new route discovery to the MAC.
    NEIGHBOR_ADDED = 13, // An entry was added to the neighbor table.
    NEIGHBOR_REMOVED = 14, // An entry was removed from the neighbor table.
    NEIGHBOR_STALE = 15, // A neighbor table entry became stale because it had not been heard from.
    JOIN_INDICATION = 16, // A node joined or rejoined to the network via this node.
    CHILD_REMOVED = 17, // An entry was removed from the child table.
    ASH_OVERFLOW_ERROR = 18, // EZSP-UART only. An overflow error occurred in the UART.
    ASH_FRAMING_ERROR = 19, // EZSP-UART only. A framing error occurred in the UART.
    ASH_OVERRUN_ERROR = 20, // EZSP-UART only. An overrun error occurred in the UART.
    NWK_FRAME_COUNTER_FAILURE = 21, // A message was dropped at the network layer because the NWK frame counter was not higher than the last message seen from that source.
    APS_FRAME_COUNTER_FAILURE = 22, // A message was dropped at the APS layer because the APS frame counter was not higher than the last message seen from that source.
    UTILITY = 23, // Utility counter for general debugging use.
    APS_LINK_KEY_NOT_AUTHORIZED = 24, // A message was dropped at the APS layer because it had APS encryption but the key associated with the sender has not been authenticated, and thus the key is not authorized for use in APS data messages.
    NWK_DECRYPTION_FAILURE = 25, // An NWK-encrypted message was received but dropped because decryption failed.
    APS_DECRYPTION_FAILURE = 26, // An APS encrypted message was received but dropped because decryption failed.
    ALLOCATE_PACKET_BUFFER_FAILURE = 27, // The number of times we failed to allocate a set of linked packet buffers. This doesn't necessarily mean that the packet buffer count was 0 at the time, but that the number requested was greater than the number free.
    RELAYED_UNICAST = 28, // The number of relayed unicast packets.
    PHY_TO_MAC_QUEUE_LIMIT_REACHED = 29, // The number of times we dropped a packet due to reaching the preset PHY to MAC queue limit (sli_802154mac_max_phy_to_mac_queue_length).
    PACKET_VALIDATE_LIBRARY_DROPPED_COUNT = 30, // The number of times we dropped a packet due to the packet-validate library checking a packet and rejecting it due to length or other formatting problems.
    TYPE_NWK_RETRY_OVERFLOW = 31, // The number of times the NWK retry queue is full and a new message failed to be added.
    PHY_CCA_FAIL_COUNT = 32, // The number of times the PHY layer was unable to transmit due to a failed CCA.
    BROADCAST_TABLE_FULL = 33, // The number of times an NWK broadcast was dropped because the broadcast table was full.
    PTA_LO_PRI_REQUESTED = 34, // The number of low priority packet traffic arbitration requests.
    PTA_HI_PRI_REQUESTED = 35, // The number of high priority packet traffic arbitration requests.
    PTA_LO_PRI_DENIED = 36, // The number of low priority packet traffic arbitration requests denied.
    PTA_HI_PRI_DENIED = 37, // The number of high priority packet traffic arbitration requests denied.
    PTA_LO_PRI_TX_ABORTED = 38, // The number of aborted low priority packet traffic arbitration transmissions.
    PTA_HI_PRI_TX_ABORTED = 39, // The number of aborted high priority packet traffic arbitration transmissions.
    ADDRESS_CONFLICT_SENT = 40,
//    CSL_RX_SCHEDULE_FAILED = 41,
    TYPE_COUNT = 41, // A placeholder giving the number of Ember counter types.
}

// The type of method used for joining.
enum EmberJoinMethod : ubyte {
    USE_MAC_ASSOCIATION = 0x00, // Normally devices use MAC Association to join a network, which respects the "permit joining" flag in the MAC Beacon. This value should be used by default.
    USE_NWK_REJOIN = 0x01, // For those networks where the "permit joining" flag is never turned on, they will need to use a ZigBee NWK Rejoin. This value causes the rejoin to be sent without NWK security and the Trust Center will be asked to send the NWK key to the device. The NWK key sent to the device can be encrypted with the device's corresponding Trust Center link key. That is determined by the EmberJoinDecision on the Trust Center returned by the emberTrustCenterJoinHandler().
    USE_NWK_REJOIN_HAVE_NWK_KEY = 0x02, // For those networks where the "permit joining" flag is never turned on, they will need to use an NWK Rejoin. If those devices have been preconfigured with the NWK key (including sequence number) they can use a secured rejoin. This is only necessary for end devices since they need a parent. Routers can simply use the EMBER_USE_CONFIGURED_NWK_STATE join method below.
    USE_CONFIGURED_NWK_STATE = 0x03, // For those networks where all network and security information is known ahead of time, a router device may be commissioned such that it does not need to send any messages to begin communicating on the network.
}

// Flags for controlling which incoming ZDO requests are passed to the application.
// To see if the application is required to send a ZDO response to an incoming message, the application must check the APS options bitfield within the incomingMessageHandler callback to see if the EMBER_APS_OPTION_ZDO_RESPONSE_REQUIRED flag is set.
enum EmberZdoConfigurationFlags : ubyte {
    APP_RECEIVES_SUPPORTED_ZDO_REQUESTS = 0x01, // Set this flag in order to receive supported ZDO request messages via the incomingMessageHandler callback. A supported ZDO request is one that is handled by the EmberZNet stack. The stack will continue to handle the request and send the appropriate ZDO response even if this configuration option is enabled.
    APP_HANDLES_UNSUPPORTED_ZDO_REQUESTS = 0x02, // Set this flag in order to receive unsupported ZDO request messages via the incomingMessageHandler callback. An unsupported ZDO request is one that is not handled by the EmberZNet stack, other than to send a 'not supported' ZDO response. If this configuration option is enabled, the stack will no longer send any ZDO response, and it is the application's responsibility to do so.
    APP_HANDLES_ZDO_ENDPOINT_REQUESTS = 0x04, // Set this flag in order to receive the following ZDO request messages via the incomingMessageHandler callback: SIMPLE_DESCRIPTOR_REQUEST, MATCH_DESCRIPTORS_REQUEST, and ACTIVE_ENDPOINTS_REQUEST. If this configuration option is enabled, the stack will no longer send any ZDO response for these requests, and it is the application's responsibility to do so.
    APP_HANDLES_ZDO_BINDING_REQUESTS = 0x08, // Set this flag in order to receive the following ZDO request messages via the incomingMessageHandler callback: BINDING_TABLE_REQUEST, BIND_REQUEST, and UNBIND_REQUEST. If this configuration option is enabled, the stack will no longer send any ZDO response for these requests, and it is the application's responsibility to do so.
}

// Type of concentrator.
enum EmberConcentratorType : ushort {
    LOW_RAM_CONCENTRATOR = 0xFFF8, // A concentrator with insufficient memory to store source routes for the entire network. Route records are sent to the concentrator prior to every inbound APS unicast.
    HIGH_RAM_CONCENTRATOR = 0xFFF9, // A concentrator with sufficient memory to store source routes for the entire network. Remote nodes stop sending route records once the concentrator has successfully received one.
}

// ZLL device state identifier.
enum EmberZllState : ushort {
    NONE = 0x0000, // No state.
    FACTORY_NEW = 0x0001, // The device is factory new.
    ADDRESS_ASSIGNMENT_CAPABLE = 0x0002, // The device is capable of assigning addresses to other devices.
    LINK_INITIATOR = 0x0010, // The device is initiating a link operation.
    LINK_PRIORITY_REQUEST = 0x0020, // The device is requesting link priority.
    NON_ZLL_NETWORK = 0x0100, // The device is on a non-ZLL network.
}

// ZLL key encryption algorithm enumeration.
enum EmberZllKeyIndex : ubyte {
    DEVELOPMENT = 0x00, // Key encryption algorithm for use during development.
    MASTER = 0x04, // Key encryption algorithm shared by all certified devices.
    CERTIFICATION = 0x0F, // Key encryption algorithm for use during development and certification.
}

// Differentiates among ZLL network operations.
enum EzspZllNetworkOperation : ubyte {
    FORM_NETWORK = 0x00, // ZLL form network command.
    JOIN_TARGET = 0x01, // ZLL join target command.
}

// Validates Source Route Overhead Information cached.
enum EzspSourceRouteOverheadInformation : ubyte {
    UNKNOWN = 0xFF, // Ezsp source route overhead unknown.
}

// Bitmask options for emberNetworkInit().
enum EmberNetworkInitBitmask : ushort {
    NO_OPTIONS = 0x0000, // No options for Network Init.
    PARENT_INFO_IN_TOKEN = 0x0001, // Save parent info (node ID and EUI64) in a token during joining/rejoin, and restore on reboot.
    END_DEVICE_REJOIN_ON_REBOOT = 0x0002, // Send a rejoin request as an end device on reboot if parent information is persisted.
}

// Network configuration for the desired radio interface for multi-phy network.
enum EmberMultiPhyNwkConfig : ubyte {
    BROADCAST_SUPPORT = 0x01, // Enable broadcast support on Routers.
}

// Duty cycle states.
enum EmberDutyCycleState : ubyte {
    TRACKING_OFF = 0, // No Duty cycle tracking or metrics are taking place.
    LBT_NORMAL = 1, // Duty Cycle is tracked and has not exceeded any thresholds.
    LBT_LIMITED_THRESHOLD_REACHED = 2, // We have exceeded the limited threshold of our total duty cycle allotment.
    LBT_CRITICAL_THRESHOLD_REACHED = 3, // We have exceeded the critical threshold of our total duty cycle allotment.
    LBT_SUSPEND_LIMIT_REACHED = 4, // We have reached the suspend limit and are blocking all outbound transmissions.
}

// Radio power modes.
enum EmberRadioPowerMode : ubyte {
    RX_ON = 0, // The radio receiver is switched on.
    OFF = 1, // The radio receiver is switched off.
}

// Entropy sources.
enum EmberEntropySource : ubyte {
    ERROR = 0, // Entropy source error.
    RADIO = 1, // Entropy source is the radio.
    MBEDTLS_TRNG = 2, // Entropy source is the TRNG powered by mbed TLS.
    MBEDTLS = 3, // Entropy source is powered by mbed TLS, the source is not TRNG.
}


// Key types recognized by Zigbee Security Manager.
enum sl_zb_sec_man_key_type : ubyte {
    NONE = 0, // No key type.
    NETWORK = 1, // Network Key (either current or alternate).
    TC_LINK = 2, // Preconfigured Trust Center Link Key.
    TC_LINK_WITH_TIMEOUT = 3, // Transient key.
    APP_LINK = 4, // Link key in table.
    ZLL_ENCRYPTION_KEY = 6, // Encryption key in ZLL.
    ZLL_PRECONFIGURED_KEY = 7, // Preconfigured key in ZLL.
    GREEN_POWER_PROXY_TABLE_KEY = 8, // GP Proxy table key.
    GREEN_POWER_SINK_TABLE_KEY = 9, // GP Sink table key.
    INTERNAL = 10, // Generic key type available to use for crypto operations.
}

// Derived key types recognized by Zigbee Security Manager
enum sl_zb_sec_man_derived_key_type : ushort {
    NONE = 0, // No derivation (use core key type directly).
    KEY_TRANSPORT_KEY = 1, // Hash core key with Key Transport Key hash.
    KEY_LOAD_KEY = 2, // Hash core key with Key Load Key hash.
    VERIFY_KEY = 3, // Perform Verify Key hash.
    TC_SWAP_OUT_KEY = 4, // Perform a simple AES hash of the key for TC backup.
    TC_HASHED_LINK_KEY = 5, // For a TC using hashed link keys, hashed the root key against the supplied EUI in context.
}

// Flags for key operations.
enum sl_zigbee_sec_man_flags : ubyte {
    NONE = 0, // No flags on operation.
    KEY_INDEX_IS_VALID = 1, // Context has a valid key index.
    EUI_IS_VALID = 2, // Context has a valid EUI64.
    UNCONFIRMED_TRANSIENT_KEY = 4, // Transient key being added hasn't yet been verified.
}

// SL Status Codes.
enum sl_status : uint
{
    OK = 0x0000, // No error.
    FAIL = 0x0001, // Generic error.
    INVALID_STATE = 0x0002, // Generic invalid state error.
    NOT_READY = 0x0003, // Module is not ready for requested operation.
    BUSY = 0x0004, // Module is busy and cannot carry out requested operation.
    IN_PROGRESS = 0x0005, // Operation is in progress and not yet complete (pass or fail).
    ABORT = 0x0006, // Operation aborted.
    TIMEOUT = 0x0007, // Operation timed out.
    PERMISSION = 0x0008, // Operation not allowed per permissions.
    WOULD_BLOCK = 0x0009, // Non-blocking operation would block.
    IDLE = 0x000A, // Operation/module is Idle, cannot carry requested operation.
    IS_WAITING = 0x000B, // Operation cannot be done while construct is waiting.
    NONE_WAITING = 0x000C, // No task/construct waiting/pending for that action/event.
    SUSPENDED = 0x000D, // Operation cannot be done while construct is suspended.
    NOT_AVAILABLE = 0x000E, // Feature not available due to software configuration.
    NOT_SUPPORTED = 0x000F, // Feature not supported.
    INITIALIZATION = 0x0010, // Initialization failed.
    NOT_INITIALIZED = 0x0011, // Module has not been initialized.
    ALREADY_INITIALIZED = 0x0012, // Module has already been initialized.
    DELETED = 0x0013, // Object/construct has been deleted.
    ISR = 0x0014, // Illegal call from ISR.
    NETWORK_UP = 0x0015, // Illegal call because network is up.
    NETWORK_DOWN = 0x0016, // Illegal call because network is down.
    NOT_JOINED = 0x0017, // Failure due to not being joined in a network.
    NO_BEACONS = 0x0018, // Invalid operation as there are no beacons.
    ALLOCATION_FAILED = 0x0019, // Generic allocation error.
    NO_MORE_RESOURCE = 0x001A, // No more resource available to perform the operation.
    EMPTY = 0x001B, // Item/list/queue is empty.
    FULL = 0x001C, // Item/list/queue is full.
    WOULD_OVERFLOW = 0x001D, // Item would overflow.
    HAS_OVERFLOWED = 0x001E, // Item/list/queue has been overflowed.
    OWNERSHIP = 0x001F, // Generic ownership error.
    IS_OWNER = 0x0020, // Already/still owning resource.
    INVALID_PARAMETER = 0x0021, // Generic invalid argument or consequence of invalid argument.
    NULL_POINTER = 0x0022, // Invalid null pointer received as argument.
    INVALID_CONFIGURATION = 0x0023, // Invalid configuration provided.
    INVALID_MODE = 0x0024, // Invalid mode.
    INVALID_HANDLE = 0x0025, // Invalid handle.
    INVALID_TYPE = 0x0026, // Invalid type for operation.
    INVALID_INDEX = 0x0027, // Invalid index.
    INVALID_RANGE = 0x0028, // Invalid range.
    INVALID_KEY = 0x0029, // Invalid key.
    INVALID_CREDENTIALS = 0x002A, // Invalid credentials.
    INVALID_COUNT = 0x002B, // Invalid count.
    INVALID_SIGNATURE = 0x002C, // Invalid signature / verification failed.
    NOT_FOUND = 0x002D, // Item could not be found.
    ALREADY_EXISTS = 0x002E, // Item already exists.
    IO = 0x002F, // Generic I/O failure.
    IO_TIMEOUT = 0x0030, // I/O failure due to timeout.
    TRANSMIT = 0x0031, // Generic transmission error.
    TRANSMIT_UNDERFLOW = 0x0032, // Transmit underflowed.
    TRANSMIT_INCOMPLETE = 0x0033, // Transmit is incomplete.
    TRANSMIT_BUSY = 0x0034, // Transmit is busy.
    RECEIVE = 0x0035, // Generic reception error.
    OBJECT_READ = 0x0036, // Failed to read on/via given object.
    OBJECT_WRITE = 0x0037, // Failed to write on/via given object.
    MESSAGE_TOO_LONG = 0x0038, // Message is too long.
    ERRNO = 0x0101, // System error: errno is set and strerror can be used to fetch the error-message.
    NET_MQTT_NO_CONN = 0x0841, // Not connected to a broker.
    NET_MQTT_LOST_CONN = 0x0842, // Connection to broker lost.
    NET_MQTT_PROTOCOL = 0x0843, // Protocol error.
    NET_MQTT_TLS_HANDSHAKE = 0x0844, // TLS negotiation failed.
    NET_MQTT_PAYLOAD_SIZE = 0x0845, // Payload size is too large.
    NET_MQTT_NOT_SUPPORTED = 0x0846, // MQTTv5 properties are set but client is not using MQTTv5.
    NET_MQTT_AUTH = 0x0847, // Authentication failed.
    NET_MQTT_ACL_DENIED = 0x0848, // Access control list deny.
    NET_MQTT_MALFORMED_UTF8 = 0x0849, // Malformed UTF-8 string in the specified MQTT-topic.
    NET_MQTT_DUPLICATE_PROPERTY = 0x084A, // An MQTTv5 property is duplicated where it is forbidden.
    NET_MQTT_QOS_NOT_SUPPORTED = 0x084B, // The requested QoS level is not supported by the broker.
    NET_MQTT_OVERSIZE_PACKET = 0x084C, // Resulting packet will become larger than the broker supports.
    PRINT_INFO_MESSAGE = 0x0900, // Only information message should be printed, without starting an application.
}

// 16-bit ZigBee network address.
alias EmberNodeId = ushort;

// 802.15.4 PAN ID.
alias EmberPanId = ushort;

// 16-bit ZigBee multicast group identifier.
alias EmberMulticastId = ushort;

// EUI 64-bit ID (an IEEE address).
alias EmberEUI64 = ubyte[8];

// The percent of duty cycle for a limit. Duty Cycle, Limits, and Thresholds are reported in units of Percent * 100 (i.e. 10000 = 100.00%, 1 = 0.01%).
alias EmberDutyCycleHectoPct = ushort;

// A library identifier
alias EmberLibraryId = ubyte;

// The presence and status of the Ember library.
alias EmberLibraryStatus = ubyte;

// The security level of the GPD.
alias EmberGpSecurityLevel = ubyte;

// The type of security key to use for the GPD.
alias EmberGpKeyType = ubyte;

// The proxy table entry status
alias EmberGpProxyTableEntryStatus = ubyte;

// The security frame counter
alias EmberGpSecurityFrameCounter = uint;

// The sink table entry status
alias EmberGpSinkTableEntryStatus = ubyte;

// Network Initialization parameters.
struct EmberNetworkInitStruct {
    EmberNetworkInitBitmask bitmask; // Configuration options for network init.
}

// Network parameters.
struct EmberNetworkParameters {
    ubyte[8] extendedPanId; // The network's extended PAN identifier.
    ushort panId; // The network's PAN identifier.
    ubyte radioTxPower; // A power setting, in dBm.
    ubyte radioChannel; // A radio channel.
    EmberJoinMethod joinMethod; // The method used to initially join the network.
    EmberNodeId nwkManagerId; // NWK Manager ID. The ID of the network manager in the current network. This may only be set at joining when using EMBER_USE_CONFIGURED_NWK_STATE as the join method.
    ubyte nwkUpdateId; // NWK Update ID. The value of the ZigBee nwkUpdateId known by the stack. This is used to determine the newest instance of the network after a PAN ID or channel change. This may only be set at joining when using EMBER_USE_CONFIGURED_NWK_STATE as the join method.
    uint channels; // NWK channel mask. The list of preferred channels that the NWK manager has told this device to use when searching for the network. This may only be set at joining when using EMBER_USE_CONFIGURED_NWK_STATE as the join method.
}

// Radio parameters.
struct EmberMultiPhyRadioParameters {
    byte radioTxPower; // A power setting, in dBm.
    ubyte radioPage; // A radio page.
    ubyte radioChannel; // A radio channel.
}

// The parameters of a ZigBee network.
struct EmberZigbeeNetwork {
    ubyte channel; // The 802.15.4 channel associated with the network.
    ushort panId; // The network's PAN identifier.
    ubyte[8] extendedPanId; // The network's extended PAN identifier.
    bool allowingJoin; // Whether the network is allowing MAC associations.
    ubyte stackProfile; // The Stack Profile associated with the network.
    ubyte nwkUpdateId; // The instance of the Network.
}

// ZigBee APS frame parameters.
struct EmberApsFrame {
    ushort profileId; // The application profile ID that describes the format of the message.
    ushort clusterId; // The cluster ID for this message.
    ubyte sourceEndpoint; // The source endpoint.
    ubyte destinationEndpoint; // The destination endpoint.
    EmberApsOption options; // A bitmask of options.
    ushort groupId; // The group ID for this message, if it is multicast mode.
    ubyte sequence; // The sequence number.
}

// An entry in the binding table.
struct EmberBindingTableEntry {
    EmberBindingType type; // The type of binding.
    ubyte local; // The endpoint on the local node.
    ushort clusterId; // A cluster ID that matches one from the local endpoint's simple descriptor. This cluster ID is set by the provisioning application to indicate which part an endpoint's functionality is bound to this particular remote node and is used to distinguish between unicast and multicast bindings. Note that a binding can be used to send messages with any cluster ID, not just the one listed in the binding.
    ubyte remote; // The endpoint on the remote node (specified by identifier).
    EmberEUI64 identifier; // A 64-bit identifier. This is either the destination EUI64 (for unicasts) or the 64-bit group address (for multicasts).
    ubyte networkIndex; // The index of the network the binding belongs to.
}

// A multicast table entry indicates that a particular endpoint is a member of a particular multicast group. Only devices with an endpoint in a multicast group will receive messages sent to that multicast group.
struct EmberMulticastTableEntry {
    EmberMulticastId multicastId; // The multicast group ID.
    ubyte endpoint; // The endpoint that is a member, or 0 if this entry is not in use (the ZDO is not a member of any multicast groups.)
    ubyte networkIndex; // The network index of the network the entry is related to.
}

// A 128-bit key.
struct EmberKeyData {
    ubyte[16] contents; // The key data.
}

// The implicit certificate used in CBKE.
struct EmberCertificateData {
    ubyte[48] contents; // The certificate data.
}

// The public key data used in CBKE.
struct EmberPublicKeyData {
    ubyte[22] contents; // The public key data.
}

// The private key data used in CBKE.
struct EmberPrivateKeyData {
    ubyte[21] contents; // The private key data.
}

// The Shared Message Authentication Code data used in CBKE.
struct EmberSmacData {
    ubyte[16] contents; // The Shared Message Authentication Code data.
}

// An ECDSA signature
struct EmberSignatureData {
    ubyte[42] contents; // The signature data.
}

// The implicit certificate used in CBKE.
struct EmberCertificate283k1Data {
    ubyte[74] contents; // The 283k1 certificate data.
}

// The public key data used in CBKE.
struct EmberPublicKey283k1Data {
    ubyte[37] contents; // The 283k1 public key data.
}

// The private key data used in CBKE.
struct EmberPrivateKey283k1Data {
    ubyte[36] contents; // The 283k1 private key data.
}

// An ECDSA signature
struct EmberSignature283k1Data {
    ubyte[72] contents; // The 283k1 signature data.
}

// The calculated digest of a message
struct EmberMessageDigest {
    ubyte[16] contents; // The calculated digest of a message.
}

// The hash context for an ongoing hash operation.
struct EmberAesMmoHashContext {
    ubyte[16] result; // The result of ongoing the hash operation.
    uint length; // The total length of the data that has been hashed so far.
}

// Beacon data structure.
struct EmberBeaconData {
    ubyte channel; // The channel of the received beacon.
    ubyte lqi; // The LQI of the received beacon.
    byte rssi; // The RSSI of the received beacon.
    ubyte depth; // The depth of the received beacon.
    ubyte nwkUpdateId; // The network update ID of the received beacon.
    byte power; // The power level of the received beacon. This field is valid only if the beacon is an enhanced beacon.
    byte parentPriority; // The TC connectivity and long uptime from capacity field.
    ushort panId; // The PAN ID of the received beacon.
    ubyte[8] extendedPanId; // The extended PAN ID of the received beacon.
    EmberNodeId sender; // The sender of the received beacon.
    bool enhanced; // Whether or not the beacon is enhanced.
    bool permitJoin; // Whether the beacon is advertising permit join.
    bool hasCapacity; // Whether the beacon is advertising capacity.
}

// Defines an iterator that is used to loop over cached beacons. Do not write to fields denoted as Private.
struct EmberBeaconIterator {
    EmberBeaconData beacon; // The retrieved beacon.
    ubyte index; // The index of the retrieved beacon.
}

// The parameters related to beacon prioritization.
struct EmberBeaconClassificationParams {
    byte minRssiForReceivingPkts; // The minimum RSSI value for receiving packets that is used in some beacon prioritization algorithms.
    ushort beaconClassificationMask; // The beacon classification mask that identifies which beacon prioritization algorithm to pick and defines the relevant parameters.
}

// A neighbor table entry stores information about the reliability of RF links to and from neighboring nodes.
struct EmberNeighborTableEntry {
    ushort shortId; // The neighbor's two-byte network id
    ubyte averageLqi; // An exponentially weighted moving average of the link quality values of incoming packets from this neighbor as reported by the PHY.
    ubyte inCost; // The incoming cost for this neighbor, computed from the average LQI. Values range from 1 for a good link to 7 for a bad link.
    ubyte outCost; // The outgoing cost for this neighbor, obtained from the most recently received neighbor exchange message from the neighbor. A value of zero means that a neighbor exchange message from the neighbor has not been received recently enough, or that our id was not present in the most recently received one.
    ubyte age; // The number of aging periods elapsed since a link status message was last received from this neighbor. The aging period is 16 seconds.
    EmberEUI64 longId; // The 8-byte EUI64 of the neighbor.
}

// A route table entry stores information about the next hop along the route to the destination.
struct EmberRouteTableEntry {
    ushort destination; // The short id of the destination. A value of 0xFFFF indicates the entry is unused.
    ushort nextHop; // The short id of the next hop to this destination.
    ubyte status; // Indicates whether this entry is active (0), being discovered (1), unused (3), or validating (4).
    ubyte age; // The number of seconds since this route entry was last used to send a packet.
    ubyte concentratorType; // Indicates whether this destination is a High RAM Concentrator (2), a Low RAM Concentrator (1), or not a concentrator (0).
    ubyte routeRecordState; // For a High RAM Concentrator, indicates whether a route record is needed (2), has been sent (1), or is no long needed (0) because a source routed message from the concentrator has been received.
}

// The security data used to set the configuration for the stack, or the retrieved configuration currently in use.
struct EmberInitialSecurityState {
    EmberInitialSecurityBitmask bitmask; // A bitmask indicating the security state used to indicate what the security configuration will be when the device forms or joins the network.
    EmberKeyData preconfiguredKey; // The pre-configured Key data that should be used when forming or joining the network. The security bitmask must be set with EMBER_HAVE_PRECONFIGURED_KEY bit to indicate that the key contains valid data.
    EmberKeyData networkKey; // The Network Key that should be used by the Trust Center when it forms the network, or the Network Key currently in use by a joined device. The security bitmask must be set with EMBER_HAVE_NETWORK_KEY to indicate that the key contains valid data.
    ubyte networkKeySequenceNumber; // The sequence number associated with the network key. This is only valid if the EMBER_HAVE_NETWORK_KEY has been set in the security bitmask.
    EmberEUI64 preconfiguredTrustCenterEui64; // This is the long address of the trust center on the network that will be joined. It is usually NOT set prior to joining the network and instead it is learned during the joining message exchange. This field is only examined if EMBER_HAVE_TRUST_CENTER_EUI64 is set in the EmberInitialSecurityState::bitmask. Most devices should clear that bit and leave this field alone. This field must be set when using commissioning mode.
}

// The security options and information currently used by the stack.
struct EmberCurrentSecurityState {
    EmberCurrentSecurityBitmask bitmask; // A bitmask indicating the security options currently in use by a device joined in the network.
    EmberEUI64 trustCenterLongAddress; // The IEEE Address of the Trust Center device.
}

// A structure containing a key and its associated data.
struct EmberKeyStruct {
    EmberKeyStructBitmask bitmask; // A bitmask indicating the presence of data within the various fields in the structure.
    EmberKeyType type; // The type of the key.
    EmberKeyData key; // The actual key data.
    uint outgoingFrameCounter; // The outgoing frame counter associated with the key.
    uint incomingFrameCounter; // The frame counter of the partner device associated with the key.
    ubyte sequenceNumber; // The sequence number associated with the key.
    EmberEUI64 partnerEUI64; // The IEEE address of the partner device also in possession of the key.
}

// Data associated with the ZLL security algorithm.
struct EmberZllSecurityAlgorithmData {
    uint transactionId; // Transaction identifier.
    uint responseId; // Response identifier.
    ushort bitmask; // Bitmask.
}

// The parameters of a ZLL network.
struct EmberZllNetwork {
    EmberZigbeeNetwork zigbeeNetwork; // The parameters of a ZigBee network.
    EmberZllSecurityAlgorithmData securityAlgorithm; // Data associated with the ZLL security algorithm.
    EmberEUI64 eui64; // Associated EUI64.
    EmberNodeId nodeId; // The node id.
    EmberZllState state; // The ZLL state.
    EmberNodeType nodeType; // The node type.
    ubyte numberSubDevices; // The number of sub devices.
    ubyte totalGroupIdentifiers; // The total number of group identifiers.
    ubyte rssiCorrection; // RSSI correction value.
}

// Describes the initial security features and requirements that will be used when forming or joining ZLL networks.
struct EmberZllInitialSecurityState {
    uint bitmask; // Unused bitmask; reserved for future use.
    EmberZllKeyIndex keyIndex; // The key encryption algorithm advertised by the application.
    EmberKeyData encryptionKey; // The encryption key for use by algorithms that require it.
    EmberKeyData preconfiguredKey; // The pre-configured link key used during classical ZigBee commissioning.
}

// Information about a specific ZLL Device.
struct EmberZllDeviceInfoRecord {
    EmberEUI64 ieeeAddress; // EUI64 associated with the device.
    ubyte endpointId; // Endpoint id.
    ushort profileId; // Profile id.
    ushort deviceId; // Device id.
    ubyte version_; // Associated version.
    ubyte groupIdCount; // Number of relevant group ids.
}

// ZLL address assignment data.
struct EmberZllAddressAssignment {
    EmberNodeId nodeId; // Relevant node id.
    EmberNodeId freeNodeIdMin; // Minimum free node id.
    EmberNodeId freeNodeIdMax; // Maximum free node id.
    EmberMulticastId groupIdMin; // Minimum group id.
    EmberMulticastId groupIdMax; // Maximum group id.
    EmberMulticastId freeGroupIdMin; // Minimum free group id.
    EmberMulticastId freeGroupIdMax; // Maximum free group id.
}

// Public API for ZLL stack data token.
struct EmberTokTypeStackZllData {
    uint bitmask; // Token bitmask.
    ushort freeNodeIdMin; // Minimum free node id.
    ushort freeNodeIdMax; // Maximum free node id.
    ushort myGroupIdMin; // Local minimum group id.
    ushort freeGroupIdMin; // Minimum free group id.
    ushort freeGroupIdMax; // Maximum free group id.
    ubyte rssiCorrection; // RSSI correction value.
}

// Public API for ZLL stack security token.
struct EmberTokTypeStackZllSecurity {
    uint bitmask; // Token bitmask.
    ubyte keyIndex; // Key index.
    ubyte[16] encryptionKey; // Encryption key.
    ubyte[16] preconfiguredKey; // Pre-configured key.
}

// A structure containing duty cycle limit configurations.
// All limits are absolute, and are required to be as follows: suspLimit > critThresh > limitThresh
// For example: suspLimit = 250 (2.5%), critThresh = 180 (1.8%), limitThresh 100 (1.00%).
struct EmberDutyCycleLimits {
    ushort vendorId; // The vendor identifier field shall contain the vendor identifier of the node.
    ubyte[7] vendorString; // The vendor string field shall contain the vendor string of the node.
}

// A structure containing per device overall duty cycle consumed (up to the suspend limit).
struct EmberPerDeviceDutyCycle {
    EmberNodeId nodeId; // Node Id of device whose duty cycle is reported.
    EmberDutyCycleHectoPct dutyCycleConsumed; // Amount of overall duty cycle consumed (up to suspend limit).
}

// The transient key data structure.
struct EmberTransientKeyData {
    EmberEUI64 eui64; // The IEEE address paired with the transient link key.
    EmberKeyData keyData; // The key data structure matching the transient key.
    EmberKeyStructBitmask bitmask; // This bitmask indicates whether various fields in the structure contain valid data.
    ushort remainingTimeSeconds; // The number of seconds remaining before the key is automatically timed out of the transient key table.
    ubyte networkIndex; // The network index indicates which NWK uses this key.
}

// A structure containing a child node's data.
struct EmberChildData {
    EmberEUI64 eui64; // The EUI64 of the child
    EmberNodeType type; // The node type of the child
    EmberNodeId id; // The short address of the child
    ubyte phy; // The phy of the child
    ubyte power; // The power of the child
    ubyte timeout; // The timeout of the child
    uint remainingTimeout; // The remaining timeout of the child in seconds
}

// A 128-bit
struct sl_zb_sec_man_key {
    ubyte[16] key; // The key data.
}

// Context for Zigbee Security Manager operations.
struct sl_zb_sec_man_context {
    sl_zb_sec_man_key_type core_key_type; // The type of key being referenced.
    ubyte key_index; // The index of the referenced key.
    sl_zb_sec_man_derived_key_type derived_type; // The type of key derivation operation to perform on a key.
    EmberEUI64 eui64; // The EUI64 associated with this key.
    ubyte multi_network_index; // Multi-network index.
    sl_zigbee_sec_man_flags flags; // Flag bitmask.
    uint psa_key_alg_permission; // Algorithm to use with this key (for PSA APIs)
}

// Metadata for network keys.
struct sl_zb_sec_man_network_key_info {
    bool network_key_set; // Whether the current network key is set.
    bool alternate_network_key_set; // Whether the alternate network key is set.
    ubyte network_key_sequence_number; // Current network key sequence number.
    ubyte alt_network_key_sequence_number; // Alternate network key sequence number.
    uint network_key_frame_counter; // Frame counter for the network key.
}

// Metadata for APS link keys.
struct sl_zb_sec_man_aps_key_metadata {
    EmberKeyStructBitmask bitmask; // Bitmask of key properties
    uint outgoing_frame_counter; // Outgoing frame counter.
    uint incoming_frame_counter; // Incoming frame counter.
    ushort ttl_in_seconds; // Remaining lifetime (for transient keys).
}

// A GP address structure.
struct EmberGpAddress {
    ubyte[8] id; // Contains either a 4-byte source ID or an 8-byte IEEE address, as indicated by the value of the applicationId field.
    ubyte applicationId; // The GPD Application ID specifying either source ID (0x00) or IEEE address (0x02).
    ubyte endpoint; // The GPD endpoint.
}

enum GP_SINK_LIST_ENTRIES = 2;

// A sink list entry.
struct EmberGpSinkListEntry {
    // TODO: CONFIRM - this whole struct might be wrong!!!
    EmberEUI64 ieeeAddress; // EUI64 associated with the device.
    ubyte endpointId; // Endpoint id.
    ushort profileId; // Profile id.
    ushort deviceId; // Device id.
    ubyte version_; // Associated version.
    ubyte groupIdCount; // Number of relevant group ids.
}

// The internal representation of a proxy table entry.
struct EmberGpProxyTableEntry {
    EmberGpProxyTableEntryStatus status; // Internal status of the proxy table entry.
    uint options; // The tunneling options (this contains both options and extendedOptions from the spec).
    EmberGpAddress gpd; // The addressing info of the GPD.
    EmberNodeId assignedAlias; // The assigned alias for the GPD.
    ubyte securityOptions; // The security options field.
    EmberGpSecurityFrameCounter gpdSecurityFrameCounter; // The security frame counter of the GPD.
    EmberKeyData gpdKey; // The key to use for GPD.
    EmberGpSinkListEntry[GP_SINK_LIST_ENTRIES] sinkList; // The list of sinks (hardcoded to 2 which is the spec minimum).
    ubyte groupcastRadius; // The groupcast radius.
    ubyte searchCounter; // The search counter.
}

// The internal representation of a sink table entry.
struct EmberGpSinkTableEntry {
    EmberGpSinkTableEntryStatus status; // Internal status of the sink table entry.
    uint options; // The tunneling options (this contains both options and extendedOptions from the spec).
    EmberGpAddress gpd; // The addressing info of the GPD.
    ubyte deviceId; // The device id for the GPD.
    EmberGpSinkListEntry[GP_SINK_LIST_ENTRIES] sinkList; // The list of sinks (hardcoded to 2 which is the spec minimum).
    EmberNodeId assignedAlias; // The assigned alias for the GPD.
    ubyte groupcastRadius; // The groupcast radius.
    ubyte securityOptions; // The security options field.
    EmberGpSecurityFrameCounter gpdSecurityFrameCounter; // The security frame counter of the GPD.
    EmberKeyData gpdKey; // The key to use for GPD.
}

// Information of a token in the token table.
struct EmberTokenInfo {
    uint nvm3Key; // NVM3 key of the token
    bool isCnt; // Token is a counter type
    bool isIdx; // Token is an indexed token
    ubyte size; // Size of the token
    ubyte arraySize; // Array size of the token
}

// Token Data
struct EmberTokenData {
    uint size; // Token data size in bytes
    ubyte[64] data; // Token data pointer
}


// Commands...
//-------------

// # Configuration Frames

// The command allows the Host to specify the desired EZSP version and must be sent before any other command.
// The response provides information about the firmware running on the NCP.
struct EZSP_Version {
    enum ushort Command = 0x0000;
    struct Request {
        ubyte desiredProtocolVersion; // The EZSP version the Host wishes to use. To successfully set the version and allow other commands, this must be same as EZSP_PROTOCOL_VERSION.
    }
    struct Response {
        ubyte protocolVersion; // The EZSP version the NCP is using.
        ubyte stackType; // The type of stack running on the NCP (2).
        ushort stackVersion; // The version number of the stack.
    }
}

// Reads a configuration value from the NCP.
struct EZSP_GetConfigurationValue {
    enum ushort Command = 0x0052;
    struct Request {
        EzspConfigId configId; // Identifies which configuration value to read.
    }
    struct Response {
        EzspStatus status; // EZSP_SUCCESS if the value was read successfully, EZSP_ERROR_INVALID_ID if the NCP does not recognize configId.
        ushort value; // The configuration value.
    }
}

// Writes a configuration value to the NCP. Configuration values can be modified by the Host after the NCP has reset. Once the status of the stack changes to EMBER_NETWORK_UP, configuration values can no longer be modified and this command will respond with EZSP_ERROR_INVALID_CALL.
struct EZSP_SetConfigurationValue {
    enum ushort Command = 0x0053;
    struct Request {
        EzspConfigId configId; // Identifies which configuration value to change.
        ushort value; // The new configuration value.
    }
    struct Response {
        EzspStatus status; // EZSP_SUCCESS if the configuration value was changed, EZSP_ERROR_OUT_OF_MEMORY if the new value exceeded the available memory, EZSP_ERROR_INVALID_VALUE if the new value was out of bounds, EZSP_ERROR_INVALID_ID if the NCP does not recognize configId, EZSP_ERROR_INVALID_CALL if configuration values can no longer be modified.
    }
}

// Read attribute data on NCP endpoints.
struct EZSP_ReadAttribute {
    enum ushort Command = 0x0108;
    struct Request {
        ubyte endpoint; // Endpoint
        ushort cluster; // Cluster.
        ushort attributeId; // Attribute ID.
        ubyte mask; // Mask.
        ushort manufacturerCode; // Manufacturer code.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        ubyte dataType; // Attribute data type.
        ubyte readLength; // Length of attribute data.
        ubyte[] dataPtr; // Attribute data.
    }
}

// Write attribute data on NCP endpoints.
struct EZSP_WriteAttribute {
    enum ushort Command = 0x0109;
    struct Request {
        ubyte endpoint; // Endpoint
        ushort cluster; // Cluster.
        ushort attributeId; // Attribute ID.
        ubyte mask; // Mask.
        ushort manufacturerCode; // Manufacturer code.
        bool overrideReadOnlyAndDataType; // Override read only and data type.
        bool justTest; // Override read only and data type.
        ubyte dataType; // Attribute data type.
        ubyte dataLength; // Attribute data length.
        ubyte[] data; // Attribute data.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Configures endpoint information on the NCP. The NCP does not remember these settings after a reset. Endpoints can be added by the Host after the NCP has reset. Once the status of the stack changes to EMBER_NETWORK_UP, endpoints can no longer be added and this command will respond with EZSP_ERROR_INVALID_CALL.
struct EZSP_AddEndpoint {
    enum ushort Command = 0x0002;
    struct Request {
        ubyte endpoint; // The application endpoint to be added.
        ushort profileId; // The endpoint's application profile.
        ushort deviceId; // The endpoint's device ID within the application profile.
        ubyte appFlags; // The device version and flags indicating description availability.
        const(ushort)[] inputClusterList; // Input cluster IDs the endpoint will accept.
        const(ushort)[] outputClusterList; // Output cluster IDs the endpoint may send.
    }
    struct Response {
        EzspStatus status; // EZSP_SUCCESS if the endpoint was added, EZSP_ERROR_OUT_OF_MEMORY if there is not enough memory available to add the endpoint, EZSP_ERROR_INVALID_VALUE if the endpoint already exists, EZSP_ERROR_INVALID_CALL if endpoints can no longer be added.
    }
}

// Allows the Host to change the policies used by the NCP to make fast decisions.
struct EZSP_SetPolicy {
    enum ushort Command = 0x0055;
    struct Request {
        EzspPolicyId policyId; // Identifies which policy to modify.
        EzspDecisionId decisionId; // The new decision for the specified policy.
    }
    struct Response {
        EzspStatus status; // EZSP_SUCCESS if the policy was changed, EZSP_ERROR_INVALID_ID if the NCP does not recognize policyId.
    }
}

// Allows the Host to read the policies used by the NCP to make fast decisions.
struct EZSP_GetPolicy {
    enum ushort Command = 0x0056;
    struct Request {
        EzspPolicyId policyId; // Identifies which policy to read.
    }
    struct Response {
        EzspStatus status; // EZSP_SUCCESS if the policy was read successfully, EZSP_ERROR_INVALID_ID if the NCP does not recognize policyId.
        EzspDecisionId decisionId; // The current decision for the specified policy.
    }
}

// Triggers a pan id update message.
struct EZSP_SendPanIdUpdate {
    enum ushort Command = 0x0057;
    struct Request {
        EmberPanId newPan; // The new Pan Id
    }
    struct Response {
        bool status; // true if the request was successfully handed to the stack, false otherwise
    }
}

// Reads a value from the NCP.
struct EZSP_GetValue {
    enum ushort Command = 0x00AA;
    struct Request {
        EzspValueId valueId; // Identifies which value to read.
    }
    struct Response {
        EzspStatus status;
        ubyte valueLength; // Both a command and response parameter. On command, the maximum size in bytes of local storage allocated to receive the returned value. On response, the actual length in bytes of the returned value.
        ubyte[] value; // The value.
    }
}

// Reads a value from the NCP but passes an extra argument specific to the value being retrieved.
struct EZSP_GetExtendedValue {
    enum ushort Command = 0x0003;
    struct Request {
        EzspExtendedValueId valueId; // Identifies which extended value ID to read.
        uint characteristics; // Identifies which characteristics of the extended value ID to read. These are specific to the value being read.
    }
    struct Response {
        EzspStatus status;
        ubyte valueLength; // Both a command and response parameter. On command, the maximum size in bytes of local storage allocated to receive the returned value. On response, the actual length in bytes of the returned value.
        ubyte[] value; // The value.
    }
}

// Writes a value to the NCP.
struct EZSP_SetValue {
    enum ushort Command = 0x00AB;
    struct Request {
        EzspValueId valueId; // Identifies which value to change.
        const(ubyte)[] value; // The new value.
    }
    struct Response {
        EzspStatus status;
    }
}

// Allows the Host to control the broadcast behaviour of a routing device used by the NCP
struct EZSP_SetPassiveAckConfig {
    enum ushort Command = 0x0105;
    struct Request {
        ubyte config; // Passive ack config enum.
        ubyte minAcksNeeded; // The minimum number of acknowledgments (re-broadcasts) to wait for until deeming the broadcast transmission complete.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}


// # Utilities Frames

// A command which does nothing. The Host can use this to set the sleep mode or to check the status of the NCP.
struct EZSP_Nop {
    enum ushort Command = 0x0005;
    struct Request {
    }
    struct Response {
    }
}

// Variable length data from the Host is echoed back by the NCP. This command has no other effects and is designed for testing the link between the Host and NCP.
struct EZSP_Echo {
    enum ushort Command = 0x0081;
    struct Request {
        ubyte dataLength; // The length of the data parameter in bytes.
        ubyte[] data; // The data to be echoed back.
    }
    struct Response {
        ubyte echoLength; // The length of the echo parameter in bytes.
        ubyte[] echo; // The echo of the data.
    }
}

// Indicates that the NCP received an invalid command.
struct EZSP_InvalidCommand {
    enum ushort Command = 0x0058;
    struct Request {
    }
    struct Response {
        EzspStatus reason; // The reason why the command was invalid.
    }
}

// Allows the NCP to respond with a pending callback.
struct EZSP_Callback {
    enum ushort Command = 0x0006;
    struct Request {
    }
    struct Response {
    }
}

// Indicates that there are currently no pending callbacks.
struct EZSP_NoCallbacks {
    enum ushort Command = 0x0007;
    struct Request {
    }
    struct Response {
    }
}

// Sets a token (8 bytes of non-volatile storage) in the Simulated EEPROM of the NCP.
struct EZSP_SetToken {
    enum ushort Command = 0x0009;
    struct Request {
        ubyte tokenId; // Which token to set.
        ubyte[8] tokenData; // The data to write to the token.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Retrieves a token (8 bytes of non-volatile storage) from the Simulated EEPROM of the NCP.
struct EZSP_GetToken {
    enum ushort Command = 0x000A;
    struct Request {
        ubyte tokenId; // Which token to read.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        ubyte[8] tokenData; // The contents of the token.
    }
}

// Retrieves a manufacturing token from the Flash Information Area of the NCP (except for EZSP_STACK_CAL_DATA which is managed by the stack).
struct EZSP_GetMfgToken {
    enum ushort Command = 0x000B;
    struct Request {
        EzspMfgTokenId tokenId; // Which manufacturing token to read.
    }
    struct Response {
        ubyte tokenDataLength; // The length of the tokenData parameter in bytes.
        ubyte[] tokenData; // The manufacturing token data.
    }
}

// Sets a manufacturing token in the Customer Information Block (CIB) area of the NCP if that token currently unset (fully erased). Cannot be used with EZSP_STACK_CAL_DATA, EZSP_STACK_CAL_FILTER, EZSP_MFG_ASH_CONFIG, or EZSP_MFG_CBKE_DATA token.
struct EZSP_SetMfgToken {
    enum ushort Command = 0x000C;
    struct Request {
        EzspMfgTokenId tokenId; // Which manufacturing token to set.
        ubyte tokenDataLength; // The length of the tokenData parameter in bytes.
        ubyte[] tokenData; // The manufacturing token data.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// A callback invoked to inform the application that a stack token has changed.
struct EZSP_StackTokenChangedHandler {
    enum ushort Command = 0x000D;
    struct Request {
    }
    struct Response {
        ushort tokenAddress; // The address of the stack token that has changed.
    }
}

// Returns a pseudorandom number.
struct EZSP_GetRandomNumber {
    enum ushort Command = 0x0049;
    struct Request {
    }
    struct Response {
        EmberStatus status; // Always returns EMBER_SUCCESS.
        ushort value; // A pseudorandom number.
    }
}

// Sets a timer on the NCP. There are 2 independent timers available for use by the Host. A timer can be cancelled by setting time to 0 or units to EMBER_EVENT_INACTIVE.
struct EZSP_SetTimer {
    enum ushort Command = 0x000E;
    struct Request {
        ubyte timerId; // Which timer to set (0 or 1).
        ushort time; // The delay before the timerHandler callback will be generated. Note that the timer clock is free running and is not synchronized with this command. This means that the actual delay will be between time and (time - 1). The maximum delay is 32767.
        EmberEventUnits units; // The units for time.
        bool repeat; // If true, a timerHandler callback will be generated repeatedly. If false, only a single timer-Handler callback will be generated.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Gets information about a timer. The Host can use this command to find out how much longer it will be before a previously set timer will generate a callback.
struct EZSP_GetTimer {
    enum ushort Command = 0x004E;
    struct Request {
        ubyte timerId; // Which timer to get information about (0 or 1).
    }
    struct Response {
        ushort time; // The delay before the timerHandler callback will be generated.
        EmberEventUnits units; // The units for time.
        bool repeat; // True if a timerHandler callback will be generated repeatedly. False if only a single timer-Handler callback will be generated.
    }
}

// A callback from the timer.
struct EZSP_TimerHandler {
    enum ushort Command = 0x000F;
    struct Request {
    }
    struct Response {
        ubyte timerId; // Which timer generated the callback (0 or 1).
    }
}

// Sends a debug message from the Host to the Network Analyzer utility via the NCP.
struct EZSP_DebugWrite {
    enum ushort Command = 0x0012;
    struct Request {
        bool binaryMessage; // true if the message should be interpreted as binary data, false if the message should be interpreted as ASCII text.
        ubyte messageLength; // The length of the messageContents parameter in bytes.
        ubyte[] messageContents; // The binary message.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Retrieves and clears Ember counters. See the EmberCounterType enumeration for the counter types.
struct EZSP_ReadAndClearCounters {
    enum ushort Command = 0x0065;
    struct Request {
    }
    struct Response {
        ushort[EmberCounterType.TYPE_COUNT] values; // A list of all counter values ordered according to the EmberCounterType enumeration.
    }
}

// Retrieves Ember counters. See the EmberCounterType enumeration for the counter types.
struct EZSP_ReadCounters {
    enum ushort Command = 0x00F1;
    struct Request {
    }
    struct Response {
        ushort[EmberCounterType.TYPE_COUNT] values; // A list of all counter values ordered according to the EmberCounterType enumeration.
    }
}

// This call is fired when a counter exceeds its threshold.
struct EZSP_CounterRolloverHandler {
    enum ushort Command = 0x00F2;
    struct Request {
    }
    struct Response {
        EmberCounterType type; // Type of Counter
    }
}

// Used to test that UART flow control is working correctly.
struct EZSP_DelayTest {
    enum ushort Command = 0x009D;
    struct Request {
        ushort delay; // Data will not be read from the host for this many milliseconds.
    }
    struct Response {
    }
}

// This retrieves the status of the passed library ID to determine if it is compiled into the stack.
struct EZSP_GetLibraryStatus {
    enum ushort Command = 0x0001;
    struct Request {
        EmberLibraryId libraryId; // The ID of the library being queried.
    }
    struct Response {
        EmberLibraryStatus status; // The status of the library being queried.
    }
}

// Allows the HOST to know whether the NCP is running the XNCP library. If so, the response contains also the manufacturer ID and the version number of the XNCP application that is running on the NCP.
struct EZSP_GetXncpInfo {
    enum ushort Command = 0x0013;
    struct Request {
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if the NCP is running the XNCP library. EMBER_INVALID_CALL otherwise.
        ushort manufacturerId; // The manufactured ID the user has defined in the XNCP application.
        ushort versionNumber; // The version number of the XNCP application.
    }
}

// Provides the customer a custom EZSP frame. On the NCP, these frames are only handled if the XNCP library is included. On the NCP side these frames are handled in the emberXNcpIncomingCustomEzspMessageCallback() callback function.
struct EZSP_CustomFrame {
    enum ushort Command = 0x0047;
    struct Request {
        ubyte payloadLength; // The length of the custom frame payload (maximum 119 bytes).
        ubyte[] payload; // The payload of the custom frame.
    }
    struct Response {
        EmberStatus status; // The status returned by the custom command.
        ubyte replyLength; // The length of the response.
        ubyte[] reply; // The response.
    }
}

// A callback indicating a custom EZSP message has been received.
struct EZSP_CustomFrameHandler {
    enum ushort Command = 0x0054;
    struct Request {
    }
    struct Response {
        const(ubyte)[] payload; // The payload of the custom frame.
    }
}

// Returns the EUI64 ID of the local node.
struct EZSP_GetEui64 {
    enum ushort Command = 0x0026;
    struct Request {
    }
    struct Response {
        EmberEUI64 eui64; // The 64-bit ID.
    }
}

// Returns the 16-bit node ID of the local node.
struct EZSP_GetNodeId {
    enum ushort Command = 0x0027;
    struct Request {
    }
    struct Response {
        EmberNodeId nodeId; // The 16-bit ID.
    }
}

// Returns number of phy interfaces present.
struct EZSP_GetPhyInterfaceCount {
    enum ushort Command = 0x00FC;
    struct Request {
    }
    struct Response {
        ubyte interfaceCount; // Value indicate how many phy interfaces present.
    }
}

// Returns the entropy source used for true random number generation.
struct EZSP_GetTrueRandomEntropySource {
    enum ushort Command = 0x004F;
    struct Request {
    }
    struct Response {
        EmberEntropySource entropySource; // Value indicates the used entropy source.
    }
}


// # Networking Frames

// Sets the manufacturer code to the specified value. The manufacturer code is one of the fields of the node descriptor.
struct EZSP_SetManufacturerCode {
    enum ushort Command = 0x0015;
    struct Request {
        ushort code; // The manufacturer code for the local node.
    }
    struct Response {
    }
}

// Sets the power descriptor to the specified value. The power descriptor is a dynamic value. Therefore, you should call this function whenever the value changes.
struct EZSP_SetPowerDescriptor {
    enum ushort Command = 0x0016;
    struct Request {
    }
    struct Response {
        ushort descriptor; // The new power descriptor for the local node.
    }
}

// Resume network operation after a reboot. The node retains its original type. This should be called on startup whether or not the node was previously part of a network. EMBER_NOT_JOINED is returned if the node is not part of a network. This command accepts options to control the network initialization.
struct EZSP_NetworkInit {
    enum ushort Command = 0x0017;
    struct Request {
        EmberNetworkInitStruct networkInitStruct; // An EmberNetworkInitStruct containing the options for initialization.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value that indicates one of the following: successful initiali-zation, EMBER_NOT_JOINED if the node is not part of a network, or the rea-son for failure.
    }
}

// Returns a value indicating whether the node is joining, joined to, or leaving a network.
struct EZSP_NetworkState {
    enum ushort Command = 0x0018;
    struct Request {
    }
    struct Response {
        EmberNetworkStatus status; // An EmberNetworkStatus value indicating the current join status.
    }
}

// A callback invoked when the status of the stack changes. If the status parameter equals EMBER_NETWORK_UP, then the getNetworkParameters command can be called to obtain the new network parameters. If any of the parameters are being stored in nonvolatile memory by the Host, the stored values should be updated.
struct EZSP_StackStatusHandler {
    enum ushort Command = 0x0019;
    struct Request {
    }
    struct Response {
        EmberStatus status; // Stack status.
    }
}

// This function will start a scan.
struct EZSP_StartScan {
    enum ushort Command = 0x001A;
    struct Request {
        EzspNetworkScanType scanType; // Indicates the type of scan to be performed. Possible values are: EZSP_ENERGY_SCAN and EZSP_ACTIVE_SCAN. For each type, the respective callback for reporting results is: ener-gyScanResultHandler and networkFoundHandler. The energy scan and active scan report errors and completion via the scanCompleteHandler.
        uint channelMask; // Bits set as 1 indicate that this particular channel should be scanned. Bits set to 0 indicate that this particular channel should not be scanned. For example, a channelMask value of 0x00000001 would indicate that only channel 0 should be scanned. Valid channels range from 11 to 26 inclu-sive. This translates to a channel mask value of 0x07FFF800. As a convenience, a value of 0 is reinterpreted as the mask for the current channel.
        ubyte duration; // Sets the exponent of the number of scan periods, where a scan period is 960 symbols. The scan will occur for ((2^duration) + 1) scan periods.
    }
    struct Response {
        sl_status status; // SL_STATUS_OK signals that the scan successfully started. Possible error responses and their meanings: SL_STATUS_MAC_SCANNING, we are already scanning; SL_STATUS_BAD_SCAN_DURATION, we have set a duration value that is not 0..14 inclusive; SL_STATUS_MAC_INCORRECT_SCAN_TYPE, we have requested an undefined scanning type; SL_STATUS_INVALID_CHANNEL_MASK, our channel mask did not specify any valid chan-nels.
    }
}

// Reports the result of an energy scan for a single channel. The scan is not complete until the scanCompleteHandler callback is called.
struct EZSP_EnergyScanResultHandler {
    enum ushort Command = 0x0048;
    struct Request {
    }
    struct Response {
        ubyte channel; // The 802.15.4 channel number that was scanned.
        int8s maxRssiValue; // The maximum RSSI value found on the channel.
    }
}

// Reports that a network was found as a result of a prior call to startScan. Gives the network parameters useful for deciding which network to join.
struct EZSP_NetworkFoundHandler {
    enum ushort Command = 0x001B;
    struct Request {
    }
    struct Response {
        EmberZigbeeNetwork networkFound; // The parameters associated with the network found.
        ubyte lastHopLqi; // The link quality from the node that generated this beacon.
        int8s lastHopRssi; // The energy level (in units of dBm) observed during the reception.
    }
}

// Returns the status of the current scan of type EZSP_ENERGY_SCAN or EZSP_ACTIVE_SCAN. EMBER_SUCCESS signals that the scan has completed. Other error conditions signify a failure to scan on the channel specified.
struct EZSP_ScanCompleteHandler {
    enum ushort Command = 0x001C;
    struct Request {
    }
    struct Response {
        ubyte channel; // The channel on which the current error occurred. Undefined for the case of EMBER_SUCCESS.
        EmberStatus status; // The error condition that occurred on the current channel. Value will be EMBER_SUCCESS when the scan has completed.
    }
}

// Returns an unused panID and channel pair found via the find unused panId scan procedure.
struct EZSP_UnusedPanIdFoundHandler {
    enum ushort Command = 0x00D2;
    struct Request {
    }
    struct Response {
        EmberPanId panId; // The unused panID which has been found.
        ubyte channel; // The channel that the unused panID was found on.
    }
}

// Starts a series of scans which will return an available panId.
struct EZSP_FindUnusedPanId {
    enum ushort Command = 0x00D3;
    struct Request {
        uint channelMask; // The channels that will be scanned for available panIds.
        ubyte duration; // The duration of the procedure.
    }
    struct Response {
        EmberStatus status; // The error condition that occurred during the scan. Value will be EMBER_SUCCESS if there are no errors.
    }
}

// Terminates a scan in progress.
struct EZSP_StopScan {
    enum ushort Command = 0x001D;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Forms a new network by becoming the coordinator.
struct EZSP_FormNetwork {
    enum ushort Command = 0x001E;
    struct Request {
        EmberNetworkParameters parameters; // Specification of the new network.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Causes the stack to associate with the network using the specified network parameters. It can take several seconds for the stack to associate with the local network. Do not send messages until the stackStatusHandler callback informs you that the stack is up.
struct EZSP_JoinNetwork {
    enum ushort Command = 0x001F;
    struct Request {
        EmberNodeType nodeType; // Specification of the role that this node will have in the network. This role must not be EMBER_COORDINATOR. To be a coordinator, use the formNetwork command.
        EmberNetworkParameters parameters; // Specification of the network with which the node should associate.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Causes the stack to associate with the network using the specified network parameters in the beacon parameter. It can take several seconds for the stack to associate with the local network. Do not send messages until the stackStatusHandler callback informs you that the stack is up. Unlike ::emberJoinNetwork(), this function does not issue an active scan before joining. Instead, it will cause the local node to issue a MAC Association Request directly to the specified target node. It is assumed that the beacon parameter is an artifact after issuing an active scan. (For more information, see emberGetBestBeacon and emberGetNextBeacon.)
struct EZSP_JoinNetworkDirectly {
    enum ushort Command = 0x003B;
    struct Request {
        EmberNodeType localNodeType; // Specifies the role that this node will have in the network. This role must not be EMBER_COORDINATOR. To be a coordinator, use the formNetwork command.
        EmberBeaconData beacon; // Specifies the network with which the node should associate.
        byte radioTxPower; // The radio transmit power to use, specified in dBm.
        bool clearBeaconsAfterNetworkUp; // If true, clear beacons in cache upon join success. If join fail, do nothing.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Causes the stack to leave the current network. This generates a stackStatusHandler callback to indicate that the network is down. The radio will not be used until after sending a formNetwork or joinNetwork command.
struct EZSP_LeaveNetwork {
    enum ushort Command = 0x0020;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// The application may call this function when contact with the network has been lost. The most common usage case is when an end device can no longer communicate with its parent and wishes to find a new one. Another case is when a device has missed a Network Key update and no longer has the current Network Key. The stack will call ezspStackStatusHandler to indicate that the network is down, then try to re-establish contact with the network by performing an active scan, choosing a network with matching extended pan id, and sending a ZigBee network rejoin request. A second call to the ezspStackStatusHandler callback indicates either the success or the failure of the attempt. The process takes approximately 150 milliseconds per channel to complete. This call replaces the emberMobileNodeHasMoved API from EmberZNet 2.x, which used MAC association and consequently took half a second longer to complete.
struct EZSP_FindAndRejoinNetwork {
    enum ushort Command = 0x0021;
    struct Request {
        bool haveCurrentNetworkKey; // This parameter tells the stack whether to try to use the current network key. If it has the current network key it will perform a secure rejoin (encrypted). If this fails the device should try an unsecure rejoin. If the Trust Center allows the rejoin then the current Network Key will be sent encrypted using the device's Link Key.
        uint channelMask; // A mask indicating the channels to be scanned. See emberStartScan for format details. A value of 0 is reinterpreted as the mask for the current channel.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Tells the stack to allow other nodes to join the network with this node as their parent. Joining is initially disabled by default.
struct EZSP_PermitJoining {
    enum ushort Command = 0x0022;
    struct Request {
        ubyte duration; // A value of 0x00 disables joining. A value of 0xFF enables joining. Any other value enables joining for that number of seconds.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Indicates that a child has joined or left.
struct EZSP_ChildJoinHandler {
    enum ushort Command = 0x0023;
    struct Request {
    }
    struct Response {
        ubyte index; // The index of the child of interest.
        bool joining; // True if the child is joining. False the child is leaving.
        EmberNodeId childId; // The node ID of the child.
        EmberEUI64 childEui64; // The EUI64 of the child.
        EmberNodeType childType; // The node type of the child.
    }
}

// Sends a ZDO energy scan request. This request may only be sent by the current network manager and must be unicast, not broadcast. See ezsp-utils.h for related macros emberSetNetworkManagerRequest() and emberChangeChannelRequest().
struct EZSP_EnergyScanRequest {
    enum ushort Command = 0x009C;
    struct Request {
        EmberNodeId target; // The network address of the node to perform the scan.
        uint scanChannels; // A mask of the channels to be scanned.
        ubyte scanDuration; // How long to scan on each channel. Allowed values are 0..5, with the scan times as specified by 802.15.4 (0 = 31ms, 1 = 46ms, 2 = 77ms, 3 = 138ms, 4 = 261ms, 5 = 507ms).
        ushort scanCount; // The number of scans to be performed on each channel (1..8).
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Returns the current network parameters.
struct EZSP_GetNetworkParameters {
    enum ushort Command = 0x0028;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        EmberNodeType nodeType; // An EmberNodeType value indicating the current node type.
        EmberNetworkParameters parameters; // The current network parameters.
    }
}

// Returns the current radio parameters based on phy index.
struct EZSP_GetRadioParameters {
    enum ushort Command = 0x00FD;
    struct Request {
        ubyte phyIndex; // Desired index of phy interface for radio parameters.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        EmberMultiPhyRadioParameters parameters; // The current radio parameters based on provided phy index.
    }
}

// Returns information about the children of the local node and the parent of the local node.
struct EZSP_GetParentChildParameters {
    enum ushort Command = 0x0029;
    struct Request {
    }
    struct Response {
        ubyte childCount; // The number of children the node currently has.
        EmberEUI64 parentEui64; // The parent's EUI64. The value is undefined for nodes without parents (coordinators and nodes that are not joined to a network).
        EmberNodeId parentNodeId; // The parent's node ID. The value is undefined for nodes without parents (coordinators and nodes that are not joined to a network).
    }
}

// Returns information about a child of the local node.
struct EZSP_GetChildData {
    enum ushort Command = 0x004A;
    struct Request {
        ubyte index; // The index of the child of interest in the child table. Possible indexes range from zero to EMBER_CHILD_TABLE_SIZE.
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if there is a child at index. EMBER_NOT_JOINED if there is no child at index.
        EmberChildData childData; // The data of the child.
    }
}

// Sets child data to the child table token.
struct EZSP_SetChildData {
    enum ushort Command = 0x00AC;
    struct Request {
        ubyte index; // The index of the child of interest in the child table. Possible indexes range from zero to (EMBER_CHILD_TABLE_SIZE - 1).
        EmberChildData childData; // The data of the child.
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if the child data is set successfully at index. EMBER_INDEX_OUT_OF_RANGE if provided index is out of range.
    }
}

// Convert a child index to a node ID
struct EZSP_ChildId {
    enum ushort Command = 0x0106;
    struct Request {
        ubyte childIndex; // The index of the child of interest in the child table. Possible indexes range from zero to EMBER_CHILD_TABLE_SIZE.
    }
    struct Response {
        EmberNodeId childId; // The node ID of the child or EMBER_NULL_NODE_ID if there isn't a child at the childIndex specified
    }
}

// Convert a node ID to a child index
struct EZSP_Id {
    enum ushort Command = 0x0107;
    struct Request {
        EmberNodeId childId; // The node ID of the child
    }
    struct Response {
        ubyte childIndex; // The child index or 0xFF if the node ID doesn't belong to a child
    }
}

// Returns the source route table total size.
struct EZSP_GetSourceRouteTableTotalSize {
    enum ushort Command = 0x00C3;
    struct Request {
    }
    struct Response {
        ubyte sourceRouteTableTotalSize; // Total size of source route table.
    }
}

// Returns the number of filled entries in the source route table.
struct EZSP_GetSourceRouteTableFilledSize {
    enum ushort Command = 0x00C2;
    struct Request {
    }
    struct Response {
        ubyte sourceRouteTableFilledSize; // The number of filled entries in the source route table.
    }
}

// Returns information about a source route table entry.
struct EZSP_GetSourceRouteTableEntry {
    enum ushort Command = 0x00C1;
    struct Request {
        ubyte index; // The index of the entry of interest in the source route table. Possible indexes range from zero to SOURCE_ROUTE_TABLE_FILLED_SIZE.
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if there is source route entry at index. EMBER_NOT_FOUND if there is no source route at index.
        EmberNodeId destination; // The node ID of the destination in that entry.
        ubyte closerIndex; // The closer node index for this source route table entry.
    }
}

// Returns the neighbor table entry at the given index. The number of active neighbors can be obtained using the neighborCount command.
struct EZSP_GetNeighbor {
    enum ushort Command = 0x0079;
    struct Request {
        ubyte index; // The index of the neighbor of interest. Neighbors are stored in ascending order by node id, with all unused entries at the end of the table.
    }
    struct Response {
        EmberStatus status; // EMBER_ERR_FATAL if the index is greater or equal to the number of active neighbors, or if the device is an end device. Returns EMBER_SUCCESS otherwise.
        EmberNeighborTableEntry value; // The contents of the neighbor table entry.
    }
}

// Returns EmberStatus depending on whether the frame counter of the node is found in the neighbor or child table. This function gets the last received frame counter as found in the Network Auxiliary header for the specified neighbor or child.
struct EZSP_GetNeighborFrameCounter {
    enum ushort Command = 0x003E;
    struct Request {
        EmberEUI64 eui64; // The EUI64 of the node.
    }
    struct Response {
        EmberStatus status; // Return EMBER_NOT_FOUND if the node is not found in the neighbor or child table. Returns EMBER_SUCCESS otherwise.
        uint returnFrameCounter; // Return the frame counter of the node from the neighbor or child table.
    }
}

// Sets the frame counter for the neighbor or child.
struct EZSP_SetNeighborFrameCounter {
    enum ushort Command = 0x00AD;
    struct Request {
        EmberEUI64 eui64; // The EUI64 of the node.
        uint frameCounter; // Return the frame counter of the node from the neighbor or child table.
    }
    struct Response {
        EmberStatus status; // Return EMBER_NOT_FOUND if the node is not found in the neighbor or child table. Returns EMBER_SUCCESS otherwise.
    }
}

// Sets the routing shortcut threshold to directly use a neighbor instead of performing routing.
struct EZSP_SetRoutingShortcutThreshold {
    enum ushort Command = 0x00D0;
    struct Request {
        ubyte costThresh; // The routing shortcut threshold to configure.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Gets the routing shortcut threshold used to differentiate between directly using a neighbor vs. performing routing.
struct EZSP_GetRoutingShortcutThreshold {
    enum ushort Command = 0x00D1;
    struct Request {
    }
    struct Response {
        ubyte routingShortcutThresh; // The routing shortcut threshold.
    }
}

// Returns the number of active entries in the neighbor table.
struct EZSP_NeighborCount {
    enum ushort Command = 0x007A;
    struct Request {
    }
    struct Response {
        ubyte value; // The number of active entries in the neighbor table.
    }
}

// Returns the route table entry at the given index. The route table size can be obtained using the getConfigurationValue command.
struct EZSP_GetRouteTableEntry {
    enum ushort Command = 0x007B;
    struct Request {
        ubyte index; // The index of the route table entry of interest.
    }
    struct Response {
        EmberStatus status; // EMBER_ERR_FATAL if the index is out of range or the device is an end device, and EMBER_SUCCESS otherwise.
        EmberRouteTableEntry value; // The contents of the route table entry.
    }
}

// Sets the radio output power at which a node is operating. Ember radios have discrete power settings. For a list of available power settings, see the technical specification for the RF communication module in your Developer Kit. Note: Care should be taken when using this API on a running network, as it will directly impact the established link qualities neighboring nodes have with the node on which it is called. This can lead to disruption of existing routes and erratic network behavior.
struct EZSP_SetRadioPower {
    enum ushort Command = 0x0099;
    struct Request {
        int8s power; // Desired radio output power, in dBm.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating the success or failure of the command.
    }
}

// Sets the channel to use for sending and receiving messages. For a list of available radio channels, see the technical specification for the RF communication module in your Developer Kit. Note: Care should be taken when using this API, as all devices on a network must use the same channel.
struct EZSP_SetRadioChannel {
    enum ushort Command = 0x009A;
    struct Request {
        ubyte channel; // Desired radio channel.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating the success or failure of the command.
    }
}

// Gets the channel in use for sending and receiving messages.
struct EZSP_GetRadioChannel {
    enum ushort Command = 0x00FF;
    struct Request {
    }
    struct Response {
        ubyte channel; // Current radio channel.
    }
}

// Set the configured 802.15.4 CCA mode in the radio.
struct EZSP_SetRadioIeee802154CcaMode {
    enum ushort Command = 0x0095;
    struct Request {
        ubyte ccaMode; // A RAIL_IEEE802154_CcaMode_t value.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating the success or failure of the command.
    }
}

// Enable/disable concentrator support.
struct EZSP_SetConcentrator {
    enum ushort Command = 0x0010;
    struct Request {
        bool on; // If this bool is true the concentrator support is enabled. Otherwise is disabled. If this bool is false all the other arguments are ignored.
        ushort concentratorType; // Must be either EMBER_HIGH_RAM_CONCENTRATOR or EMBER_LOW_RAM_CONCENTRATOR. The former is used when the caller has enough memory to store source routes for the whole network. In that case, remote nodes stop sending route records once the concentrator has successfully received one. The latter is used when the concentrator has insufficient RAM to store all outbound source routes. In that case, route records are sent to the concentrator prior to every inbound APS unicast.
        ushort minTime; // The minimum amount of time that must pass between MTORR broadcasts.
        ushort maxTime; // The maximum amount of time that can pass between MTORR broadcasts.
        ubyte routeErrorThreshold; // The number of route errors that will trigger a re-broadcast of the MTORR.
        ubyte deliveryFailureThreshold; // The number of APS delivery failures that will trigger a re-broadcast of the MTORR.
        ubyte maxHops; // The maximum number of hops that the MTORR broadcast will be allowed to have. A value of 0 will be converted to the EMBER_MAX_HOPS value set by the stack.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Sets the error code that is sent back from a router with a broken route.
struct EZSP_SetBrokenRouteErrorCode {
    enum ushort Command = 0x0011;
    struct Request {
        ubyte errorCode; // Desired error code.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating the success or failure of the command.
    }
}

// This causes to initialize the desired radio interface other than native and form a new network by becoming the coordinator with same panId as native radio network.
struct EZSP_MultiPhyStart {
    enum ushort Command = 0x00F8;
    struct Request {
        ubyte phyIndex; // Index of phy interface. The native phy index would be always zero hence valid phy index starts from one.
        ubyte page; // Desired radio channel page.
        ubyte channel; // Desired radio channel.
        byte power; // Desired radio output power, in dBm.
        EmberMultiPhyNwkConfig bitmask; // Network configuration bitmask.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// This causes to bring down the radio interface other than native.
struct EZSP_MultiPhyStop {
    enum ushort Command = 0x00F9;
    struct Request {
        ubyte phyIndex; // Index of phy interface. The native phy index would be always zero hence valid phy index starts from one.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Sets the radio output power for desired phy interface at which a node is operating. Ember radios have discrete power settings. For a list of available power settings, see the technical specification for the RF communication module in your Developer Kit. Note: Care should be taken when using this api on a running network, as it will directly impact the established link qualities neighboring nodes have with the node on which it is called. This can lead to disruption of existing routes and erratic network behavior.
struct EZSP_MultiPhySetRadioPower {
    enum ushort Command = 0x00FA;
    struct Request {
        ubyte phyIndex; // Index of phy interface. The native phy index would be always zero hence valid phy index starts from one.
        byte power; // Desired radio output power, in dBm.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating the success or failure of the command.
    }
}

// Send Link Power Delta Request from a child to its parent
struct EZSP_SendLinkPowerDeltaRequest {
    enum ushort Command = 0x00F7;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating the success or failure of sending the request.
    }
}

// Sets the channel for desired phy interface to use for sending and receiving messages. For a list of available radio pages and channels, see the technical specification for the RF communication module in your Developer Kit. Note: Care should be taken when using this API, as all devices on a network must use the same page and channel.
struct EZSP_MultiPhySetRadioChannel {
    enum ushort Command = 0x00FB;
    struct Request {
        ubyte phyIndex; // Index of phy interface. The native phy index would be always zero hence valid phy index starts from one.
        ubyte page; // Desired radio channel page.
        ubyte channel; // Desired radio channel.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating the success or failure of the command.
    }
}

// Obtains the current duty cycle state.
struct EZSP_GetDutyCycleState {
    enum ushort Command = 0x0035;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating the success or failure of the command.
        EmberDutyCycleState returnedState; // The current duty cycle state in effect.
    }
}

// Set the current duty cycle limits configuration. The Default limits set by stack if this call is not made.
struct EZSP_SetDutyCycleLimitsInStack {
    enum ushort Command = 0x0040;
    struct Request {
        EmberDutyCycleLimits limits; // The duty cycle limits configuration to utilize.
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if the duty cycle limit configurations set successfully, EMBER_BAD_ARGUMENT if set illegal value such as setting only one of the limits to default or violates constraints Susp > Crit > Limi, EMBER_INVALID_CALL if device is operating on 2.4Ghz
    }
}

// Obtains the current duty cycle limits that were previously set by a call to emberSetDutyCycleLimitsInStack(), or the defaults set by the stack if no set call was made.
struct EZSP_GetDutyCycleLimits {
    enum ushort Command = 0x004B;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating the success or failure of the command.
        EmberDutyCycleLimits returnedLimits; // Return current duty cycle limits if returnedLimits is not NULL
    }
}

// Returns the duty cycle of the stack's connected children that are being monitored, up to maxDevices. It indicates the amount of overall duty cycle they have consumed (up to the suspend limit). The first entry is always the local stack's nodeId, and thus the total aggregate duty cycle for the device. The passed pointer arrayOfDeviceDutyCycles MUST have space for maxDevices.
struct EZSP_GetCurrentDutyCycle {
    enum ushort Command = 0x004C;
    struct Request {
        ubyte maxDevices; // Number of devices to retrieve consumed duty cycle.
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if the duty cycles were read successfully, EMBER_BAD_ARGUMENT maxDevices is greater than EMBER_MAX_END_DEVICE_CHILDREN + 1.
        ubyte[134] arrayOfDeviceDutyCycles; // Consumed duty cycles up to maxDevices. When the number of children that are being monitored is less than maxDevices, the EmberNodeId element in the EmberPerDeviceDutyCycle will be 0xFFFF.
    }
}

// Callback fires when the duty cycle state has changed
struct EZSP_DutyCycleHandler {
    enum ushort Command = 0x004D;
    struct Request {
    }
    struct Response {
        ubyte channelPage; // The channel page whose duty cycle state has changed.
        ubyte channel; // The channel number whose duty cycle state has changed.
        EmberDutyCycleState state; // The current duty cycle state.
        ubyte totalDevices; // The total number of connected end devices that are being monitored for duty cycle.
        EmberPerDeviceDutyCycle arrayOfDeviceDutyCycles; // Consumed duty cycles of end devices that are being monitored. The first entry always be the local stack's nodeId, and thus the total aggregate duty cycle for the device.
    }
}

// Returns the first beacon in the cache. Beacons are stored in cache after issuing an active scan.
struct EZSP_GetFirstBeacon {
    enum ushort Command = 0x003D;
    struct Request {
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if first beacon found, EMBER_BAD_ARGUMENT if input parameters are invalid, EMBER_INVALID_CALL if no beacons stored, EMBER_ERR_FATAL if no first beacon found.
        EmberBeaconIterator beaconIterator; // The iterator to use when returning the first beacon. This argument must not be NULL.
    }
}

// Returns the next beacon in the cache. Beacons are stored in cache after issuing an active scan.
struct EZSP_GetNextBeacon {
    enum ushort Command = 0x0004;
    struct Request {
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if next beacon found, EMBER_BAD_ARGUMENT if input parameters are invalid, EMBER_ERR_FATAL if no next beacon found.
        EmberBeaconData beacon; // The next beacon retrieved. It is assumed that emberGetFirstBeacon has been called first. This argument must not be NULL.
    }
}

// Returns the number of cached beacons that have been collected from a scan.
struct EZSP_GetNumStoredBeacons {
    enum ushort Command = 0x0008;
    struct Request {
    }
    struct Response {
        ubyte numBeacons; // The number of cached beacons that have been collected from a scan.
    }
}

// Clears all cached beacons that have been collected from a scan.
struct EZSP_ClearStoredBeacons {
    enum ushort Command = 0x003C;
    struct Request {
    }
    struct Response {
    }
}

// This call sets the radio channel in the stack and propagates the information to the hardware.
struct EZSP_SetLogicalAndRadioChannel {
    enum ushort Command = 0x00B9;
    struct Request {
        ubyte radioChannel; // The radio channel to be set.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Get the logical channel from the ZLL stack.
struct EZSP_SetLogicalChannel {
    enum ushort Command = 0x00BA;
    struct Request {
    }
    struct Response {
        ubyte logicalChannel;
    }
}


// # Binding Frames

// Deletes all binding table entries.
struct EZSP_ClearBindingTable {
    enum ushort Command = 0x002A;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Sets an entry in the binding table.
struct EZSP_SetBinding {
    enum ushort Command = 0x002B;
    struct Request {
        ubyte index; // The index of a binding table entry.
        EmberBindingTableEntry value; // The contents of the binding entry.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Gets an entry from the binding table.
struct EZSP_GetBinding {
    enum ushort Command = 0x002C;
    struct Request {
        ubyte index; // The index of a binding table entry.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        EmberBindingTableEntry value; // The contents of the binding entry.
    }
}

// Deletes a binding table entry.
struct EZSP_DeleteBinding {
    enum ushort Command = 0x002D;
    struct Request {
        ubyte index; // The index of a binding table entry.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Indicates whether any messages are currently being sent using this binding table entry. Note that this command does not indicate whether a binding is clear. To determine whether a binding is clear, check whether the type field of the EmberBindingTableEntry has the value EMBER_UNUSED_BINDING.
struct EZSP_BindingIsActive {
    enum ushort Command = 0x002E;
    struct Request {
        ubyte index; // The index of a binding table entry.
    }
    struct Response {
        bool active; // True if the binding table entry is active, false otherwise.
    }
}

// Returns the node ID for the binding's destination, if the ID is known. If a message is sent using the binding and the destination's ID is not known, the stack will discover the ID by broadcasting a ZDO address request. The application can avoid the need for this discovery by using setBindingRemoteNodeId when it knows the correct ID via some other means. The destination's node ID is forgotten when the binding is changed, when the local node reboots or, much more rarely, when the destination node changes its ID in response to an ID conflict.
struct EZSP_GetBindingRemoteNodeId {
    enum ushort Command = 0x002F;
    struct Request {
        ubyte index; // The index of a binding table entry.
    }
    struct Response {
        EmberNodeId nodeId; // The short ID of the destination node or EMBER_NULL_NODE_ID if no destination is known.
    }
}

// Set the node ID for the binding's destination. See getBindingRemoteNodeId for a description.
struct EZSP_SetBindingRemoteNodeId {
    enum ushort Command = 0x0030;
    struct Request {
        ubyte index; // The index of a binding table entry.
        EmberNodeId nodeId; // The short ID of the destination node.
    }
    struct Response {
    }
}

// The NCP used the external binding modification policy to decide how to handle a remote set binding request. The Host cannot change the current decision, but it can change the policy for future decisions using the setPolicy command. This frame is a response to the callback command.
struct EZSP_RemoteSetBindingHandler {
    enum ushort Command = 0x0031;
    struct Request {
    }
    struct Response {
        EmberBindingTableEntry entry; // The requested binding.
        ubyte index; // The index at which the binding was added.
        EmberStatus policyDecision; // EMBER_SUCCESS if the binding was added to the table and any other status if not.
    }
}

// The NCP used the external binding modification policy to decide how to handle a remote delete binding request. The Host cannot change the current decision, but it can change the policy for future decisions using the setPolicy command. This frame is a response to the callback command.
struct EZSP_RemoteDeleteBindingHandler {
    enum ushort Command = 0x0032;
    struct Request {
    }
    struct Response {
        ubyte index; // The index of the binding whose deletion was requested.
        EmberStatus policyDecision; // EMBER_SUCCESS if the binding was removed from the table and any other status if not.
    }
}


// # Messaging Frames

// Returns the maximum size of the payload. The size depends on the security level in use.
struct EZSP_MaximumPayloadLength {
    enum ushort Command = 0x0033;
    struct Request {
    }
    struct Response {
        ubyte apsLength; // The maximum APS payload length.
    }
}

// Sends a unicast message as per the ZigBee specification. The message will arrive at its destination only if there is a known route to the destination node. Setting the ENABLE_ROUTE_DISCOVERY option will cause a route to be discovered if none is known. Setting the FORCE_ROUTE_DISCOVERY option will force route discovery. Routes to end-device children of the local node are always known. Setting the APS_RETRY option will cause the message to be retransmitted until either a matching acknowledgement is received or three transmissions have been made. Note: Using the FORCE_ROUTE_DISCOVERY option will cause the first transmission to be consumed by a route request as part of discovery, so the application payload of this packet will not reach its destination on the first attempt. If you want the packet to reach its destination, the APS_RETRY option must be set so that another attempt is made to transmit the message with its application payload after the route has been constructed. Note: When sending fragmented messages, the stack will only assign a new APS sequence number for the first fragment of the message (i.e., EMBER_APS_OPTION_FRAGMENT is set and the low-order byte of the groupId field in the APS frame is zero). For all subsequent fragments of the same message, the application must set the sequence number field in the APS frame to the sequence number assigned by the stack to the first fragment.
struct EZSP_SendUnicast {
    enum ushort Command = 0x0034;
    struct Request {
        EmberOutgoingMessageType type; // Specifies the outgoing message type. Must be one of EMBER_OUTGOING_DIRECT, EMBER_OUTGOING_VIA_ADDRESS_TABLE, or EMBER_OUTGOING_VIA_BINDING.
        EmberNodeId indexOrDestination; // Depending on the type of addressing used, this is either the EmberNodeId of the destination, an index into the address table, or an index into the binding table.
        EmberApsFrame apsFrame; // The APS frame which is to be added to the message.
        ubyte messageTag; // A value chosen by the Host. This value is used in the ezspMessageSentHandler response to refer to this message.
        const(ubyte)[] messageContents; // Content of the message.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        ubyte sequence; // The sequence number that will be used when this message is transmitted.
    }
}

// Sends a broadcast message as per the ZigBee specification.
struct EZSP_SendBroadcast {
    enum ushort Command = 0x0036;
    struct Request {
        EmberNodeId destination; // The destination to which to send the broadcast. This must be one of the three ZigBee broadcast addresses.
        EmberApsFrame apsFrame; // The APS frame for the message.
        ubyte radius; // The message will be delivered to all nodes within radius hops of the sender. A radius of zero is converted to EMBER_MAX_HOPS.
        ubyte messageTag; // A value chosen by the Host. This value is used in the ezspMessageSentHandler response to refer to this message.
        const(ubyte)[] messageContents; // The broadcast message.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        ubyte sequence; // The sequence number that will be used when this message is transmitted.
    }
}

// Sends a proxied broadcast message as per the ZigBee specification.
struct EZSP_ProxyBroadcast {
    enum ushort Command = 0x0037;
    struct Request {
        EmberNodeId source; // The source from which to send the broadcast.
        EmberNodeId destination; // The destination to which to send the broadcast. This must be one of the three ZigBee broadcast addresses.
        ubyte nwkSequence; // The network sequence number for the broadcast.
        EmberApsFrame apsFrame; // The APS frame for the message.
        ubyte radius; // The message will be delivered to all nodes within radius hops of the sender. A radius of zero is converted to EMBER_MAX_HOPS.
        ubyte messageTag; // A value chosen by the Host. This value is used in the ezspMessageSentHandler response to refer to this message.
        const(ubyte)[] messageContents; // The broadcast message.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        ubyte apsSequence; // The APS sequence number that will be used when this message is transmitted.
    }
}

// Sends a multicast message to all endpoints that share a specific multicast ID and are within a specified number of hops of the sender.
struct EZSP_SendMulticast {
    enum ushort Command = 0x0038;
    struct Request {
        EmberApsFrame apsFrame; // The APS frame for the message. The multicast will be sent to the groupId in this frame.
        ubyte hops; // The message will be delivered to all nodes within this number of hops of the sender. A value of zero is converted to EMBER_MAX_HOPS.
        ubyte nonmemberRadius; // The number of hops that the message will be forwarded by devices that are not members of the group. A value of 7 or greater is treated as infinite.
        ubyte messageTag; // A value chosen by the Host. This value is used in the ezspMessageSentHandler response to refer to this message.
        const(ubyte)[] messageContents; // The multicast message.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value. For any result other than EMBER_SUCCESS, the message will not be sent. EMBER_SUCCESS - The message has been submitted for transmission. EMBER_INVALID_BINDING_INDEX - The bindingTableIndex refers to a non-multicast binding. EMBER_NETWORK_DOWN - The node is not part of a network. EMBER_MESSAGE_TOO_LONG - The message is too large to fit in a MAC layer frame. EMBER_NO_BUFFERS - The free packet buffer pool is empty. EMBER_NETWORK_BUSY - Insufficient resources available in Network or MAC layers to send message.
        ubyte sequence; // The sequence number that will be used when this message is transmitted.
    }
}

// Sends a multicast message to all endpoints that share a specific multicast ID and are within a specified number of hops of the sender.
struct EZSP_SendMulticastWithAlias {
    enum ushort Command = 0x003A;
    struct Request {
        EmberApsFrame apsFrame; // The APS frame for the message. The multicast will be sent to the groupId in this frame.
        ubyte hops; // The message will be delivered to all nodes within this number of hops of the sender. A value of zero is converted to EMBER_MAX_HOPS.
        ubyte nonmemberRadius; // The number of hops that the message will be forwarded by devices that are not members of the group. A value of 7 or greater is treated as infinite.
        ushort alias_; // The alias source address
        ubyte nwkSequence; // the alias sequence number
        ubyte messageTag; // A value chosen by the Host. This value is used in the ezspMessageSentHandler response to refer to this message.
        const(ubyte)[] messageContents; // The multicast message.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value. For any result other than EMBER_SUCCESS, the message will not be sent. EMBER_SUCCESS - The message has been submitted for transmission. EMBER_INVALID_BINDING_INDEX - The bindingTableIndex refers to a non-multicast binding. EMBER_NETWORK_DOWN - The node is not part of a network. EMBER_MESSAGE_TOO_LONG - The message is too large to fit in a MAC layer frame. EMBER_NO_BUFFERS - The free packet buffer pool is empty. EMBER_NETWORK_BUSY - Insufficient resources available in Network or MAC layers to send message.
        ubyte sequence; // The sequence number that will be used when this message is transmitted.
    }
}

// Sends a reply to a received unicast message. The incomingMessageHandler callback for the unicast being replied to supplies the values for all the parameters except the reply itself.
struct EZSP_SendReply {
    enum ushort Command = 0x0039;
    struct Request {
        EmberNodeId sender; // Value supplied by incoming unicast.
        EmberApsFrame apsFrame; // Value supplied by incoming unicast.
        ubyte messageLength; // The length of the messageContents parameter in bytes.
        ubyte[] messageContents; // The reply message.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value. EMBER_INVALID_CALL - The EZSP_UNICAST_REPLIES_POLICY is set to EZSP_HOST_WILL_NOT_SUPPLY_REPLY. This means the NCP will automatically send an empty reply. The Host must change the policy to EZSP_HOST_WILL_SUPPLY_REPLY before it can supply the reply. There is one exception to this rule: In the case of responses to message fragments, the host must call sendReply when a message fragment is received. In this case, the policy set on the NCP does not matter. The NCP expects a sendReply call from the Host for message fragments regardless of the current policy settings. EMBER_NO_BUFFERS - Not enough memory was available to send the reply. EMBER_NETWORK_BUSY - Either no route or insufficient resources available. EMBER_SUCCESS - The reply was successfully queued for transmission.
    }
}

// A callback indicating the stack has completed sending a message.
struct EZSP_MessageSentHandler {
    enum ushort Command = 0x003F;
    struct Request {
    }
    struct Response {
        EmberOutgoingMessageType type; // The type of message sent.
        ushort indexOrDestination; // The destination to which the message was sent, for direct unicasts, or the address table or binding index for other unicasts. The value is unspecified for multicasts and broadcasts.
        EmberApsFrame apsFrame; // The APS frame for the message.
        ubyte messageTag; // The value supplied by the Host in the ezspSendUnicast, ezspSendBroadcast or ezspSendMulticast command.
        EmberStatus status; // An EmberStatus value of EMBER_SUCCESS if an ACK was received from the destination or EMBER_DELIVERY_FAILED if no ACK was received.
        const(ubyte)[] message; // The unicast message supplied by the Host. The message contents are only included here if the decision for the messageContentsInCallback policy is messageTagAndContentsInCallback.
    }
}

// Sends a route request packet that creates routes from every node in the network back to this node. This function should be called by an application that wishes to communicate with many nodes, for example, a gateway, central monitor, or controller. A device using this function was referred to as an 'aggregator' in EmberZNet 2.x and earlier, and is referred to as a 'concentrator' in the ZigBee specification and EmberZNet 3.
// This function enables large scale networks, because the other devices do not have to individually perform bandwidth-intensive route discoveries. Instead, when a remote node sends an APS unicast to a concentrator, its network layer automatically delivers a special route record packet first, which lists the network ids of all the intermediate relays. The concentrator can then use source routing to send outbound APS unicasts. (A source routed message is one in which the entire route is listed in the network layer header.) This allows the concentrator to communicate with thousands of devices without requiring large route tables on neighboring nodes.
// This function is only available in ZigBee Pro (stack profile 2), and cannot be called on end devices. Any router can be a concentrator (not just the coordinator), and there can be multiple concentrators on a network.
// Note that a concentrator does not automatically obtain routes to all network nodes after calling this function. Remote applications must first initiate an inbound APS unicast.
// Many-to-one routes are not repaired automatically. Instead, the concentrator application must call this function to rediscover the routes as necessary, for example, upon failure of a retried APS message. The reason for this is that there is no scalable one-size-fits-all route repair strategy. A common and recommended strategy is for the concentrator application to refresh the routes by calling this function periodically.
struct EZSP_SendManyToOneRouteRequest {
    enum ushort Command = 0x0041;
    struct Request {
        ushort concentratorType; // Must be either EMBER_HIGH_RAM_CONCENTRATOR or EMBER_LOW_RAM_CONCENTRATOR. The former is used when the caller has enough memory to store source routes for the whole network. In that case, remote nodes stop sending route records once the concentrator has successfully received one. The latter is used when the concentrator has insufficient RAM to store all outbound source routes. In that case, route records are sent to the concentrator prior to every inbound APS unicast.
        ubyte radius; // The maximum number of hops the route request will be relayed. A radius of zero is converted to EMBER_MAX_HOPS.
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if the route request was successfully submitted to the transmit queue, and EMBER_ERR_FATAL otherwise.
    }
}

// Periodically request any pending data from our parent. Setting interval to 0 or units to EMBER_EVENT_INACTIVE will generate a single poll.
struct EZSP_PollForData {
    enum ushort Command = 0x0042;
    struct Request {
        ushort interval; // The time between polls. Note that the timer clock is free running and is not synchronized with this command. This means that the time will be between interval and (interval - 1). The maximum interval is 32767.
        EmberEventUnits units; // The units for interval.
        ubyte failureLimit; // The number of poll failures that will be tolerated before a pollCompleteHandler callback is generated. A value of zero will result in a callback for every poll. Any status value apart from EMBER_SUCCESS and EMBER_MAC_NO_DATA is counted as a failure.
    }
    struct Response {
        EmberStatus status; // The result of sending the first poll.
    }
}

// Indicates the result of a data poll to the parent of the local node.
struct EZSP_PollCompleteHandler {
    enum ushort Command = 0x0043;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value: EMBER_SUCCESS - Data was received in response to the poll. EMBER_MAC_NO_DATA - No data was pending. EMBER_DELIVERY_FAILED - The poll message could not be sent. EMBER_MAC_NO_ACK_RECEIVED - The poll message was sent but not acknowledged by the parent.
    }
}

// Indicates that the local node received a data poll from a child.
struct EZSP_PollHandler {
    enum ushort Command = 0x0044;
    struct Request {
    }
    struct Response {
        EmberNodeId childId; // The node ID of the child that is requesting data.
        bool transmitExpected; // True if transmit is expected, false otherwise.
    }
}

// A callback indicating a message has been received containing the EUI64 of the sender. This callback is called immediately before the incomingMessageHandler callback. It is not called if the incoming message did not contain the EUI64 of the sender.
struct EZSP_IncomingSenderEui64Handler {
    enum ushort Command = 0x0062;
    struct Request {
    }
    struct Response {
        EmberEUI64 senderEui64; // The EUI64 of the sender
    }
}

// A callback indicating a message has been received.
struct EZSP_IncomingMessageHandler {
    enum ushort Command = 0x0045;
    struct Request {
    }
    struct Response {
        EmberIncomingMessageType type; // The type of the incoming message. One of the following: EMBER_INCOMING_UNICAST, EMBER_INCOMING_UNICAST_REPLY, EMBER_INCOMING_MULTICAST, EMBER_INCOMING_MULTICAST_LOOPBACK, EMBER_INCOMING_BROADCAST, EMBER_INCOMING_BROADCAST_LOOPBACK
        EmberApsFrame apsFrame; // The APS frame from the incoming message.
        ubyte lastHopLqi; // The link quality from the node that last relayed the message.
        int8s lastHopRssi; // The energy level (in units of dBm) observed during the reception.
        EmberNodeId sender; // The sender of the message.
        ubyte bindingIndex; // The index of a binding that matches the message or 0xFF if there is no matching binding.
        ubyte addressIndex; // The index of the entry in the address table that matches the sender of the message or 0xFF if there is no matching entry.
        const(ubyte)[] message; // The incoming message.
    }
}

// Sets source route discovery(MTORR) mode to on, off, reschedule
struct EZSP_SetSourceRouteDiscoveryMode {
    enum ushort Command = 0x005A;
    struct Request {
        ubyte mode; // Source route discovery mode: off:0, on:1, reschedule:2
    }
    struct Response {
        uint remainingTime; // Remaining time(ms) until next MTORR broadcast if the mode is on, MAX_INT32U_VALUE if the mode is off
    }
}

// A callback indicating that a many-to-one route to the concentrator with the given short and long id is available for use.
struct EZSP_IncomingManyToOneRouteRequestHandler {
    enum ushort Command = 0x007D;
    struct Request {
    }
    struct Response {
        EmberNodeId source; // The short id of the concentrator.
        EmberEUI64 longId; // The EUI64 of the concentrator.
        ubyte cost; // The path cost to the concentrator. The cost may decrease as additional route request packets for this discovery arrive, but the callback is made only once.
    }
}

// A callback invoked when a route error message is received. The error indicates that a problem routing to or from the target node was encountered.
struct EZSP_IncomingRouteErrorHandler {
    enum ushort Command = 0x0080;
    struct Request {
    }
    struct Response {
        EmberStatus status; // EMBER_SOURCE_ROUTE_FAILURE or EMBER_MANY_TO_ONE_ROUTE_FAILURE.
        EmberNodeId target; // The short id of the remote node.
    }
}

// A callback invoked when a network status/route error message is received. The error indicates that there was a problem sending/receiving messages from the target node
struct EZSP_IncomingNetworkStatusHandler {
    enum ushort Command = 0x00C4;
    struct Request {
    }
    struct Response {
        ubyte errorCode; // One byte over-the-air error code from network status message
        EmberNodeId target; // The short ID of the remote node
    }
}

// Send the network key to a destination.
struct EZSP_UnicastCurrentNetworkKey {
    enum ushort Command = 0x0050;
    struct Request {
        EmberNodeId targetShort; // The destination node of the key.
        EmberEUI64 targetLong; // The long address of the destination node.
        EmberNodeId parentShortId; // The parent node of the destination node.
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if send was successful
    }
}

// Indicates whether any messages are currently being sent using this address table entry. Note that this function does not indicate whether the address table entry is unused. To determine whether an address table entry is unused, check the remote node ID. The remote node ID will have the value EMBER_TABLE_ENTRY_UNUSED_NODE_ID when the address table entry is not in use.
struct EZSP_AddressTableEntryIsActive {
    enum ushort Command = 0x005B;
    struct Request {
        ubyte addressTableIndex; // The index of an address table entry.
    }
    struct Response {
        bool active; // True if the address table entry is active, false otherwise.
    }
}

// Sets the EUI64 of an address table entry. This function will also check other address table entries, the child table and the neighbor table to see if the node ID for the given EUI64 is already known. If known then this function will also set node ID. If not known it will set the node ID to EMBER_UNKNOWN_NODE_ID.
struct EZSP_SetAddressTableRemoteEui64 {
    enum ushort Command = 0x005C;
    struct Request {
        ubyte addressTableIndex; // The index of an address table entry.
        EmberEUI64 eui64; // The EUI64 to use for the address table entry.
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if the EUI64 was successfully set, and EMBER_ADDRESS_TABLE_ENTRY_IS_ACTIVE otherwise.
    }
}

// Sets the short ID of an address table entry. Usually the application will not need to set the short ID in the address table. Once the remote EUI64 is set the stack is capable of figuring out the short ID on its own. However, in cases where the application does set the short ID, the application must set the remote EUI64 prior to setting the short ID.
struct EZSP_SetAddressTableRemoteNodeId {
    enum ushort Command = 0x005D;
    struct Request {
        ubyte addressTableIndex; // The index of an address table entry.
        EmberNodeId id; // The short ID corresponding to the remote node whose EUI64 is stored in the address table at the given index or EMBER_TABLE_ENTRY_UNUSED_NODE_ID which indicates that the entry stored in the address table at the given index is not in use.
    }
    struct Response {
    }
}

// Gets the EUI64 of an address table entry.
struct EZSP_GetAddressTableRemoteEui64 {
    enum ushort Command = 0x005E;
    struct Request {
        ubyte addressTableIndex; // The index of an address table entry.
    }
    struct Response {
        EmberEUI64 eui64; // The EUI64 of the address table entry is copied to this location.
    }
}

// Gets the short ID of an address table entry.
struct EZSP_GetAddressTableRemoteNodeId {
    enum ushort Command = 0x005F;
    struct Request {
        ubyte addressTableIndex; // The index of an address table entry.
    }
    struct Response {
        EmberNodeId nodeId; // One of the following: The short ID corresponding to the remote node whose EUI64 is stored in the address table at the given index. EMBER_UNKNOWN_NODE_ID - Indicates that the EUI64 stored in the address table at the given index is valid but the short ID is currently unknown. EMBER_DISCOVERY_ACTIVE_NODE_ID - Indicates that the EUI64 stored in the address table at the given location is valid and network address discovery is underway. EMBER_TABLE_ENTRY_UNUSED_NODE_ID - Indicates that the entry stored in the address table at the given index is not in use.
    }
}

// Tells the stack whether or not the normal interval between retransmissions of a retried unicast message should be increased by EMBER_INDIRECT_TRANSMISSION_TIMEOUT. The interval needs to be increased when sending to a sleepy node so that the message is not retransmitted until the destination has had time to wake up and poll its parent. The stack will automatically extend the timeout: - For our own sleepy children. - When an address response is received from a parent on behalf of its child. - When an indirect transaction expiry route error is received. - When an end device announcement is received from a sleepy node.
struct EZSP_SetExtendedTimeout {
    enum ushort Command = 0x007E;
    struct Request {
        EmberEUI64 remoteEui64; // The address of the node for which the timeout is to be set.
        bool extendedTimeout; // true if the retry interval should be increased by EMBER_INDIRECT_TRANSMISSION_TIMEOUT. false if the normal retry interval should be used.
    }
    struct Response {
    }
}

// Indicates whether or not the stack will extend the normal interval between retransmissions of a retried unicast message by EMBER_INDIRECT_TRANSMISSION_TIMEOUT.
struct EZSP_GetExtendedTimeout {
    enum ushort Command = 0x007F;
    struct Request {
        EmberEUI64 remoteEui64; // The address of the node for which the timeout is to be returned.
    }
    struct Response {
        bool extendedTimeout; // true if the retry interval will be increased by EMBER_INDIRECT_TRANSMISSION_TIMEOUT and false if the normal retry interval will be used.
    }
}

// Replaces the EUI64, short ID and extended timeout setting of an address table entry. The previous EUI64, short ID and extended timeout setting are returned.
struct EZSP_ReplaceAddressTableEntry {
    enum ushort Command = 0x0082;
    struct Request {
        ubyte addressTableIndex; // The index of the address table entry that will be modified.
        EmberEUI64 newEui64; // The EUI64 to be written to the address table entry.
        EmberNodeId newId; // One of the following: The short ID corresponding to the new EUI64. EMBER_UNKNOWN_NODE_ID if the new EUI64 is valid but the short ID is unknown and should be discovered by the stack. EMBER_TABLE_ENTRY_UNUSED_NODE_ID if the address table entry is now unused.
        bool newExtendedTimeout; // true if the retry interval should be increased by EMBER_INDIRECT_TRANSMISSION_TIMEOUT. false if the normal retry interval should be used.
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if the EUI64, short ID and extended timeout setting were successfully modified, and EMBER_ADDRESS_TABLE_ENTRY_IS_ACTIVE otherwise.
        EmberEUI64 oldEui64; // The EUI64 of the address table entry before it was modified.
        EmberNodeId oldId; // One of the following: The short ID corresponding to the EUI64 before it was modified. EMBER_UNKNOWN_NODE_ID if the short ID was unknown. EMBER_DISCOVERY_ACTIVE_NODE_ID if discovery of the short ID was underway. EMBER_TABLE_ENTRY_UNUSED_NODE_ID if the address table entry was unused.
        bool oldExtendedTimeout; // true if the retry interval was being increased by EMBER_INDIRECT_TRANSMISSION_TIMEOUT. false if the normal retry interval was be- ing used.
    }
}

// Returns the node ID that corresponds to the specified EUI64. The node ID is found by searching through all stack tables for the specified EUI64.
struct EZSP_LookupNodeIdByEui64 {
    enum ushort Command = 0x0060;
    struct Request {
        EmberEUI64 eui64; // The EUI64 of the node to look up.
    }
    struct Response {
        EmberNodeId nodeId; // The short ID of the node or EMBER_NULL_NODE_ID if the short ID is not known.
    }
}

// Returns the EUI64 that corresponds to the specified node ID. The EUI64 is found by searching through all stack tables for the specified node ID.
struct EZSP_LookupEui64ByNodeId {
    enum ushort Command = 0x0061;
    struct Request {
        EmberNodeId nodeId; // The short ID of the node to look up.
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if the EUI64 was found, EMBER_ERR_FATAL if the EUI64 is not known.
        EmberEUI64 eui64; // The EUI64 of the node.
    }
}

// Gets an entry from the multicast table.
struct EZSP_GetMulticastTableEntry {
    enum ushort Command = 0x0063;
    struct Request {
        ubyte index; // The index of a multicast table entry.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        EmberMulticastTableEntry value; // The contents of the multicast entry.
    }
}

// Sets an entry in the multicast table.
struct EZSP_SetMulticastTableEntry {
    enum ushort Command = 0x0064;
    struct Request {
        ubyte index; // The index of a multicast table entry
        EmberMulticastTableEntry value; // The contents of the multicast entry.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// A callback invoked by the EmberZNet stack when an id conflict is discovered, that is, two different nodes in the network were found to be using the same short id. The stack automatically removes the conflicting short id from its internal tables (address, binding, route, neighbor, and child tables). The application should discontinue any other use of the id.
struct EZSP_IdConflictHandler {
    enum ushort Command = 0x007C;
    struct Request {
    }
    struct Response {
        EmberNodeId id; // The short id for which a conflict was detected
    }
}

// Write the current node Id, PAN ID, or Node type to the tokens
struct EZSP_WriteNodeData {
    enum ushort Command = 0x00FE;
    struct Request {
        bool erase; // Erase the node type or not
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Transmits the given message without modification. The MAC header is assumed to be configured in the message at the time this function is called.
struct EZSP_SendRawMessage {
    enum ushort Command = 0x0096;
    struct Request {
        ubyte messageLength; // The length of the messageContents parameter in bytes.
        ubyte[] messageContents; // The raw message.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Transmits the given message without modification. The MAC header is assumed to be configured in the message at the time this function is called.
struct EZSP_SendRawMessageExtended {
    enum ushort Command = 0x0051;
    struct Request {
        ubyte messageLength; // The length of the messageContents parameter in bytes.
        ubyte[] messageContents; // The raw message.
        ubyte priority; // transmit priority.
        bool useCca; // Should we enable CCA or not.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// A callback invoked by the EmberZNet stack when a MAC passthrough message is received.
struct EZSP_MacPassthroughMessageHandler {
    enum ushort Command = 0x0097;
    struct Request {
    }
    struct Response {
        EmberMacPassthroughType messageType; // The type of MAC passthrough message received.
        ubyte lastHopLqi; // The link quality from the node that last relayed the message.
        int8s lastHopRssi; // The energy level (in units of dBm) observed during reception.
        const(ubyte)[] message; // The raw message that was received.
    }
}

// A callback invoked by the EmberZNet stack when a raw MAC message that has matched one of the application's configured MAC filters.
struct EZSP_MacFilterMatchMessageHandler {
    enum ushort Command = 0x0046;
    struct Request {
    }
    struct Response {
        ubyte filterIndexMatch; // The index of the filter that was matched.
        EmberMacPassthroughType legacyPassthroughType; // The type of MAC passthrough message received.
        ubyte lastHopLqi; // The link quality from the node that last relayed the message.
        int8s lastHopRssi; // The energy level (in units of dBm) observed during reception.
        ubyte messageLength; // The length of the messageContents parameter in bytes.
        ubyte[] messageContents; // The raw message that was received.
    }
}

// A callback invoked by the EmberZNet stack when the MAC has finished transmitting a raw message.
struct EZSP_RawTransmitCompleteHandler {
    enum ushort Command = 0x0098;
    struct Request {
    }
    struct Response {
        EmberStatus status; // EMBER_SUCCESS if the transmission was successful, or EMBER_DELIVERY_FAILED if not
    }
}

// This function is useful to sleepy end devices. This function will set the retry interval (in milliseconds) for mac data poll. This interval is the time in milliseconds the device waits before retrying a data poll when a MAC level data poll fails for any reason.
struct EZSP_SetMacPollFailureWaitTime {
    enum ushort Command = 0x00F4;
    struct Request {
        ubyte waitBeforeRetryIntervalMs; // Time in seconds the device waits before retrying a data poll when a MAC level data poll fails for any reason.
    }
    struct Response {
    }
}

// Sets the priority masks and related variables for choosing the best beacon.
struct EZSP_SetBeaconClassificationParams {
    enum ushort Command = 0x00EF;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The attempt to set the parameters returns EMBER_SUCCESS.
        EmberBeaconClassificationParams param; // Gets the beacon prioritization related variable.
    }
}

// Gets the priority masks and related variables for choosing the best beacon.
struct EZSP_GetBeaconClassificationParams {
    enum ushort Command = 0x00F3;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The attempt to get the parameters returns EMBER_SUCCESS.
        EmberBeaconClassificationParams param; // Gets the beacon prioritization related variable.
    }
}


// # Security Frames

// Sets the security state that will be used by the device when it forms or joins the network. This call should not be used when restoring saved network state via networkInit as this will result in a loss of security data and will cause communication problems when the device re-enters the network.
struct EZSP_SetInitialSecurityState {
    enum ushort Command = 0x0068;
    struct Request {
        EmberInitialSecurityState state; // The security configuration to be set.
    }
    struct Response {
        EmberStatus success; // The success or failure code of the operation.
    }
}

// Gets the current security state that is being used by a device that is joined in the network.
struct EZSP_GetCurrentSecurityState {
    enum ushort Command = 0x0069;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The success or failure code of the operation.
        EmberCurrentSecurityState state; // The security configuration in use by the stack.
    }
}

// Exports a key from security manager based on passed context.
struct EZSP_ExportKey {
    enum ushort Command = 0x0114;
    struct Request {
        sl_zb_sec_man_context context; // Metadata to identify the requested key.
    }
    struct Response {
        sl_zb_sec_man_key key; // Data to store the exported key in.
        sl_status status; // The success or failure code of the operation.
    }
}

// Imports a key into security manager based on passed context.
struct EZSP_ImportKey {
    enum ushort Command = 0x0115;
    struct Request {
        sl_zb_sec_man_context context; // Metadata to identify where the imported key should be stored.
        sl_zb_sec_man_key key; // The key to be imported.
    }
    struct Response {
        sl_status status; // The success or failure code of the operation.
    }
}

// A callback to inform the application that the Network Key has been updated and the node has been switched over to use the new key. The actual key being used is not passed up, but the sequence number is.
struct EZSP_SwitchNetworkKeyHandler {
    enum ushort Command = 0x006e;
    struct Request {
    }
    struct Response {
        ubyte sequenceNumber; // The sequence number of the new network key.
    }
}

// This function searches through the Key Table and tries to find the entry that matches the passed search criteria.
struct EZSP_FindKeyTableEntry {
    enum ushort Command = 0x0075;
    struct Request {
        EmberEUI64 address; // The address to search for. Alternatively, all zeros may be passed in to search for the first empty entry.
        bool linkKey; // This indicates whether to search for an entry that contains a link key or a master key. true means to search for an entry with a Link Key.
    }
    struct Response {
        ubyte index; // The index of the entry that matches the search criteria. A value of 0x00FF is returned if not matching entry is found.
    }
}

// This function sends an APS TransportKey command containing the current trust center link key. The node to which the command is sent is specified via the short and long address arguments.
struct EZSP_SendTrustCenterLinkKey {
    enum ushort Command = 0x0067;
    struct Request {
        EmberNodeId destinationNodeId; // The short address of the node to which this command will be sent
        EmberEUI64 destinationEui64; // The long address of the node to which this command will be sent
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success of failure of the operation
    }
}

// This function erases the data in the key table entry at the specified index. If the index is invalid, false is returned.
struct EZSP_EraseKeyTableEntry {
    enum ushort Command = 0x0076;
    struct Request {
        ubyte index; // The index of entry to erase.
    }
    struct Response {
        EmberStatus status; // The success or failure of the operation.
    }
}

// This function clears the key table of the current network.
struct EZSP_ClearKeyTable {
    enum ushort Command = 0x00B1;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The success or failure of the operation.
    }
}

// A function to request a Link Key from the Trust Center with another device on the Network (which could be the Trust Center). A Link Key with the Trust Center is possible but the requesting device cannot be the Trust Center. Link Keys are optional in ZigBee Standard Security and thus the stack cannot know whether the other device supports them. If EMBER_REQUEST_KEY_TIMEOUT is non-zero on the Trust Center and the partner device is not the Trust Center, both devices must request keys with their partner device within the time period. The Trust Center only supports one outstanding key request at a time and therefore will ignore other requests. If the timeout is zero then the Trust Center will immediately respond and not wait for the second request. The Trust Center will always immediately respond to requests for a Link Key with it. Sleepy devices should poll at a higher rate until a response is received or the request times out. The success or failure of the request is returned via ezspZigbeeKeyEstablishmentHandler(...).
struct EZSP_RequestLinkKey {
    enum ushort Command = 0x0014;
    struct Request {
        EmberEUI64 partner; // This is the IEEE address of the partner device that will share the link key.
    }
    struct Response {
        EmberStatus status; // The success or failure of sending the request. This is not the final result of the attempt. ezspZigbeeKeyEstablishmentHandler(...) will return that.
    }
}

// Requests a new link key from the Trust Center. This function starts by sending a Node Descriptor request to the Trust Center to verify its R21+ stack version compliance. A Request Key message will then be sent, followed by a Verify Key Confirm message.
struct EZSP_UpdateTcLinkKey {
    enum ushort Command = 0x006C;
    struct Request {
        ubyte maxAttempts; // The maximum number of attempts a node should make when sending the Node Descriptor, Request Key, and Verify Key Confirm messages. The number of attempts resets for each message type sent (e.g., if maxAttempts is 3, up to 3 Node Descriptors are sent, up to 3 Request Keys, and up to 3 Verify Key Confirm messages are sent).
    }
    struct Response {
        EmberStatus status; // The success or failure of sending the request. If the Node Descriptor is successfully transmitted, ezspZigbeeKeyEstablishmentHandler(...) will be called at a later time with a final status result.
    }
}

// This is a callback that indicates the success or failure of an attempt to establish a key with a partner device.
struct EZSP_ZigbeeKeyEstablishmentHandler {
    enum ushort Command = 0x009B;
    struct Request {
    }
    struct Response {
        EmberEUI64 partner; // This is the IEEE address of the partner that the device successfully established a key with. This value is all zeros on a failure.
        EmberKeyStatus status; // This is the status indicating what was established or why the key establishment failed.
    }
}

// Clear all of the transient link keys from RAM.
struct EZSP_ClearTransientLinkKeys {
    enum ushort Command = 0x006B;
    struct Request {
    }
    struct Response {
    }
}

// Retrieve information about the current and alternate network key, excluding their contents.
struct EZSP_GetNetworkKeyInfo {
    enum ushort Command = 0x0116;
    struct Request {
    }
    struct Response {
        sl_status status; // Success or failure of retrieving network key info.
        sl_zb_sec_man_network_key_info network_key_info; // Information about current and alternate network keys.
    }
}

// Retrieve metadata about an APS link key. Does not retrieve contents.
struct EZSP_GetApsKeyInfo {
    enum ushort Command = 0x010C;
    struct Request {
        sl_zb_sec_man_context context_in; // Context used to input information about key.
    }
    struct Response {
        EmberEUI64 eui; // EUI64 associated with this APS link key
        sl_zb_sec_man_aps_key_metadata key_data; // Metadata about the referenced key.
        sl_status status; // Status of metadata retrieval operation.
    }
}

// Import an application link key into the key table.
struct EZSP_ImportLinkKey {
    enum ushort Command = 0x010E;
    struct Request {
        ubyte index; // Index where this key is to be imported to.
        EmberEUI64 address; // EUI64 this key is associated with.
        sl_zb_sec_man_key plaintext_key; // The key data to be imported.
    }
    struct Response {
        sl_status status; // Status of key import operation.
    }
}

// Export the link key at given index from the key table.
struct EZSP_ExportLinkKeyByIndex {
    enum ushort Command = 0x010F;
    struct Request {
        ubyte index; // Index of key to export.
    }
    struct Response {
        EmberEUI64 eui; // EUI64 associated with the exported key
        sl_zb_sec_man_key plaintext_key; // The exported key
        sl_zb_sec_man_aps_key_metadata key_data; // Metadata about the key
        sl_status status; // Status of key export operation
    }
}

// Export the link key associated with the given EUI from the key table.
struct EZSP_ExportLinkKeyByEui {
    enum ushort Command = 0x010D;
    struct Request {
        EmberEUI64 eui; // EUI64 associated with the key to export.
    }
    struct Response {
        sl_zb_sec_man_key plaintext_key; // The exported key
        ubyte index; // Key index of the exported key
        sl_zb_sec_man_aps_key_metadata key_data; // Metadata about the key
        sl_status status; // Status of key export operation
    }
}

// Check whether a key context can be used to load a valid key.
struct EZSP_CheckKeyContext {
    enum ushort Command = 0x0110;
    struct Request {
        sl_zb_sec_man_context context; // Context struct to check the validity of.
    }
    struct Response {
        sl_status status; // Validity of the checked context.
    }
}

// Import a transient link key.
struct EZSP_ImportTransientKey {
    enum ushort Command = 0x0111;
    struct Request {
        EmberEUI64 eui64; // EUI64 associated with this transient key.
        sl_zb_sec_man_key plaintext_key; // The key to import.
        sl_zigbee_sec_man_flags flags; // Flags associated with this transient key.
    }
    struct Response {
        sl_status status; // Status of key import operation.
    }
}

// Export a transient link key from a given table index.
struct EZSP_ExportTransientKeyByIndex {
    enum ushort Command = 0x0112;
    struct Request {
        ubyte index; // Index to export from.
    }
    struct Response {
        sl_zb_sec_man_context context; // Context struct for export operation.
        sl_zb_sec_man_key plaintext_key; // The exported key.
        sl_zb_sec_man_aps_key_metadata key_data; // Metadata about the key.
        sl_status status; // Status of key export operation.
    }
}

// Export a transient link key associated with a given EUI64
struct EZSP_ExportTransientKeyByEui {
    enum ushort Command = 0x0113;
    struct Request {
        EmberEUI64 eui; // Index to export from.
    }
    struct Response {
        sl_zb_sec_man_context context; // Context struct for export operation.
        sl_zb_sec_man_key plaintext_key; // The exported key.
        sl_zb_sec_man_aps_key_metadata key_data; // Metadata about the key.
        sl_status status; // Status of key export operation.
    }
}


// # Trust Center Frames

// The NCP used the trust center behavior policy to decide whether to allow a new node to join the network. The Host cannot change the current decision, but it can change the policy for future decisions using the setPolicy command.
struct EZSP_TrustCenterJoinHandler {
    enum ushort Command = 0x0024;
    struct Request {
    }
    struct Response {
        EmberNodeId newNodeId; // The Node Id of the node whose status changed
        EmberEUI64 newNodeEui64; // The EUI64 of the node whose status changed.
        EmberDeviceUpdate status; // The status of the node: Secure Join/Rejoin, Unsecure Join/Rejoin, Device left.
        EmberJoinDecision policyDecision; // An EmberJoinDecision reflecting the decision made.
        EmberNodeId parentOfNewNodeId; // The parent of the node whose status has changed.
    }
}

// This function broadcasts a new encryption key, but does not tell the nodes in the network to start using it. To tell nodes to switch to the new key, use emberSendNetworkKeySwitch(). This is only valid for the Trust Center/Coordinator. It is up to the application to determine how quickly to send the Switch Key after sending the alternate encryption key.
struct EZSP_BroadcastNextNetworkKey {
    enum ushort Command = 0x0073;
    struct Request {
        EmberKeyData key; // An optional pointer to a 16-byte encryption key (EMBER_ENCRYPTION_KEY_SIZE). An all zero key may be passed in, which will cause the stack to randomly generate a new key.
    }
    struct Response {
        EmberStatus status; // EmberStatus value that indicates the success or failure of the command.
    }
}

// This function broadcasts a switch key message to tell all nodes to change to the sequence number of the previously sent Alternate Encryption Key.
struct EZSP_BroadcastNetworkKeySwitch {
    enum ushort Command = 0x0074;
    struct Request {
    }
    struct Response {
        EmberStatus status; // EmberStatus value that indicates the success or failure of the command.
    }
}

// This routine processes the passed chunk of data and updates the hash context based on it. If the 'finalize' parameter is not set, then the length of the data passed in must be a multiple of 16. If the 'finalize' parameter is set then the length can be any value up 1-16, and the final hash value will be calculated.
struct EZSP_AesMmoHash {
    enum ushort Command = 0x006F;
    struct Request {
        EmberAesMmoHashContext context; // The hash context to update.
        bool finalize; // This indicates whether the final hash value should be calculated
        ubyte length; // The length of the data to hash.
        ubyte[] data; // The data to hash.
    }
    struct Response {
        EmberStatus status; // The result of the operation
        EmberAesMmoHashContext returnContext; // The updated hash context.
    }
}

// This command sends an APS remove device using APS encryption to the destination indicating either to remove itself from the network, or one of its children.
struct EZSP_RemoveDevice {
    enum ushort Command = 0x00A8;
    struct Request {
        EmberNodeId destShort; // The node ID of the device that will receive the message
        EmberEUI64 destLong; // The long address (EUI64) of the device that will receive the message.
        EmberEUI64 targetLong; // The long address (EUI64) of the device to be removed.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success, or the reason for failure
    }
}

// This command will send a unicast transport key message with a new NWK key to the specified device. APS encryption using the device's existing link key will be used.
struct EZSP_UnicastNwkKeyUpdate {
    enum ushort Command = 0x00A9;
    struct Request {
        EmberNodeId destShort; // The node ID of the device that will receive the message
        EmberEUI64 destLong; // The long address (EUI64) of the device that will receive the message.
        EmberKeyData key; // The NWK key to send to the new device.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success, or the reason for failure
    }
}


// # Certificate-Based Key Exchange (CBKE) Frames

// This call starts the generation of the ECC Ephemeral Public/Private key pair. When complete it stores the private key. The results are returned via ezspGenerateCbkeKeysHandler().
struct EZSP_GenerateCbkeKeys {
    enum ushort Command = 0x00A4;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The result of the CBKE operation.
    }
}

// A callback by the Crypto Engine indicating that a new ephemeral public/private key pair has been generated. The public/private key pair is stored on the NCP, but only the associated public key is returned to the host. The node's associated certificate is also returned.
struct EZSP_GenerateCbkeKeysHandler {
    enum ushort Command = 0x009E;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The result of the CBKE operation.
        EmberPublicKeyData ephemeralPublicKey; // The generated ephemeral public key.
    }
}

// Calculates the SMAC verification keys for both the initiator and responder roles of CBKE using the passed parameters and the stored public/private key pair previously generated with ezspGenerateKeysRetrieveCert(). It also stores the unverified link key data in temporary storage on the NCP until the key establishment is complete.
struct EZSP_CalculateSmacs {
    enum ushort Command = 0x009F;
    struct Request {
        bool amInitiator; // The role of this device in the Key Establishment protocol.
        EmberCertificateData partnerCertificate; // The key establishment partner's implicit certificate.
        EmberPublicKeyData partnerEphemeralPublicKey; // The key establishment partner's ephemeral public key
    }
    struct Response {
        EmberStatus status; // The result of the CBKE operation.
    }
}

// A callback to indicate that the NCP has finished calculating the Secure Message Authentication Codes (SMAC) for both the initiator and responder. The associated link key is kept in temporary storage until the host tells the NCP to store or discard the key via emberClearTemporaryDataMaybeStoreLinkKey().
struct EZSP_CalculateSmacsHandler {
    enum ushort Command = 0x00A0;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The Result of the CBKE operation.
        EmberSmacData initiatorSmac; // The calculated value of the initiator's SMAC
        EmberSmacData responderSmac; // The calculated value of the responder's SMAC
    }
}

// This call starts the generation of the ECC 283k1 curve Ephemeral Public/Private key pair. When complete it stores the private key. The results are returned via ezspGenerateCbkeKeysHandler283k1().
struct EZSP_GenerateCbkeKeys283k1 {
    enum ushort Command = 0x00E8;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The result of the CBKE operation.
    }
}

// A callback by the Crypto Engine indicating that a new 283k1 ephemeral public/private key pair has been generated. The public/private key pair is stored on the NCP, but only the associated public key is returned to the host. The node's associated certificate is also returned.
struct EZSP_GenerateCbkeKeysHandler283k1 {
    enum ushort Command = 0x00E9;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The result of the CBKE operation.
        EmberPublicKey283k1Data ephemeralPublicKey; // The generated ephemeral public key.
    }
}

// Calculates the SMAC verification keys for both the initiator and responder roles of CBKE for the 283k1 ECC curve using the passed parameters and the stored public/private key pair previously generated with ezspGenerateKeysRetrieveCert283k1(). It also stores the unverified link key data in temporary storage on the NCP until the key establishment is complete.
struct EZSP_CalculateSmacs283k1 {
    enum ushort Command = 0x00EA;
    struct Request {
        bool amInitiator; // The role of this device in the Key Establishment protocol.
        EmberCertificate283k1Data partnerCertificate; // The key establishment partner's implicit certificate.
        EmberPublicKey283k1Data partnerEphemeralPublicKey; // The key establishment partner's ephemeral public key
    }
    struct Response {
        EmberStatus status; // The result of the CBKE operation.
    }
}

// A callback to indicate that the NCP has finished calculating the Secure Message Authentication Codes (SMAC) for both the initiator and responder for the CBKE 283k1 Library. The associated link key is kept in temporary storage until the host tells the NCP to store or discard the key via emberClearTemporaryDataMaybeStoreLinkKey().
struct EZSP_CalculateSmacsHandler283k1 {
    enum ushort Command = 0x00EB;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The Result of the CBKE operation.
        EmberSmacData initiatorSmac; // The calculated value of the initiator's SMAC
        EmberSmacData responderSmac; // The calculated value of the responder's SMAC
    }
}

// LEGACY FUNCTION: This functionality has been replaced by a single bit in the EmberApsFrame, EMBER_APS_OPTION_DSA_SIGN. Devices wishing to send signed messages should use that as it requires fewer function calls and message buffering. The dsaSignHandler response is still called when EMBER_APS_OPTION_DSA_SIGN is used. However, this function is still supported. This function begins the process of signing the passed message contained within the messageContents array. If no other ECC operation is going on, it will immediately return with EMBER_OPERATION_IN_PROGRESS to indicate the start of ECC operation. It will delay a period of time to let APS retries take place, but then it will shut down the radio and consume the CPU processing until the signing is complete. This may take up to 1 second. The signed message will be returned in the dsaSignHandler response. Note that the last byte of the messageContents passed to this function has special significance. As the typical use case for DSA signing is to sign the ZCL payload of a DRLC Report Event Status message in SE 1.0, there is often both a signed portion (ZCL payload) and an unsigned portion (ZCL header). The last byte in the content of messageToSign is therefore used as a special indicator to signify how many bytes of leading data in the array should be excluded during the signing process. If the signature needs to cover the entire array (all bytes except the last one), the caller should ensure that the last byte of messageContents is 0x00. When the signature operation is complete, this final byte will be replaced by the signature type indicator (0x01 for ECDSA signatures), and the actual signature will be appended to the original contents after this byte.
struct EZSP_DsaSign {
    enum ushort Command = 0x00A6;
    struct Request {
        ubyte messageLength; // The length of the messageContents parameter in bytes.
        ubyte[] messageContents; // The message contents for which to create a signature. Per above notes, this may include a leading portion of data not included in the signature, in which case the last byte of this array should be set to the index of the first byte to be considered for signing. Otherwise, the last byte of messageContents should be 0x00 to indicate that a signature should occur across the entire contents.
    }
    struct Response {
        EmberStatus status; // EMBER_OPERATION_IN_PROGRESS if the stack has queued up the operation for execution. EMBER_INVALID_CALL if the operation can't be performed in this context, possibly because another ECC operation is pending.
    }
}

// The handler that returns the results of the signing operation. On success, the signature will be appended to the original message (including the signature type indicator that replaced the startIndex field for the signing) and both are returned via this callback.
struct EZSP_DsaSignHandler {
    enum ushort Command = 0x00A7;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The result of the DSA signing operation.
        ubyte messageLength; // The length of the messageContents parameter in bytes.
        ubyte[] messageContents; // The message and attached which includes the original message and the appended signature.
    }
}

// Verify that signature of the associated message digest was signed by the private key of the associated certificate.
struct EZSP_DsaVerify {
    enum ushort Command = 0x00A3;
    struct Request {
        EmberMessageDigest digest; // The AES-MMO message digest of the signed data. If dsaSign command was used to generate the signature for this data, the final byte (replaced by signature type of 0x01) in the messageContents array passed to dsaSign is included in the hash context used for the digest calculation.
        EmberCertificateData signerCertificate; // The certificate of the signer. Note that the signer's certificate and the verifier's certificate must both be issued by the same Certificate Authority, so they should share the same CA Public Key.
        EmberSignatureData receivedSig; // The signature of the signed data.
    }
    struct Response {
        EmberStatus status; // The result of the DSA verification operation.
    }
}

// This callback is executed by the stack when the DSA verification has completed and has a result. If the result is EMBER_SUCCESS, the signature is valid. If the result is EMBER_SIGNATURE_VERIFY_FAILURE then the signature is invalid. If the result is anything else then the signature verify operation failed and the validity is unknown.
struct EZSP_DsaVerifyHandler {
    enum ushort Command = 0x0078;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The result of the DSA verification operation.
    }
}

// Verify that signature of the associated message digest was signed by the private key of the associated certificate.
struct EZSP_DsaVerify283k1 {
    enum ushort Command = 0x00B0;
    struct Request {
        EmberMessageDigest digest; // The AES-MMO message digest of the signed data. If dsaSign command was used to generate the signature for this data, the final byte (replaced by signature type of 0x01) in the messageContents array passed to dsaSign is included in the hash context used for the digest calculation.
        EmberCertificate283k1Data signerCertificate; // The certificate of the signer. Note that the signer's certificate and the verifier's certificate must both be issued by the same Certificate Authority, so they should share the same CA Public Key.
        EmberSignature283k1Data receivedSig; // The signature of the signed data.
    }
    struct Response {
        EmberStatus status; // The result of the DSA verification operation.
    }
}

// Sets the device's CA public key, local certificate, and static private key on the NCP associated with this node.
struct EZSP_SetPreinstalledCbkeData {
    enum ushort Command = 0x00A2;
    struct Request {
        EmberPublicKeyData caPublic; // The Certificate Authority's public key.
        EmberCertificateData myCert; // The node's new certificate signed by the CA.
        EmberPrivateKeyData myKey; // The node's new static private key.
    }
    struct Response {
        EmberStatus status; // The result of the operation.
    }
}

// Sets the device's 283k1 curve CA public key, local certificate, and static private key on the NCP associated with this node.
struct EZSP_SavePreinstalledCbkeData283k1 {
    enum ushort Command = 0x00ED;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The result of the operation.
    }
}


// # Mfglib Frames

// Activate use of mfglib test routines and enables the radio receiver to report packets it receives to the mfgLibRxHandler() callback. These packets will not be passed up with a CRC failure. All other mfglib functions will return an error until the mfglibStart() has been called
struct EZSP_MfglibStart {
    enum ushort Command = 0x0083;
    struct Request {
        bool rxCallback; // true to generate a mfglibRxHandler callback when a packet is received.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Deactivate use of mfglib test routines; restores the hardware to the state it was in prior to mfglibStart() and stops receiving packets started by mfglibStart() at the same time.
struct EZSP_MfglibEnd {
    enum ushort Command = 0x0084;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Starts transmitting an unmodulated tone on the currently set channel and power level. Upon successful return, the tone will be transmitting. To stop transmitting tone, application must call mfglibStopTone(), allowing it the flexibility to determine its own criteria for tone duration (time, event, etc.)
struct EZSP_MfglibStartTone {
    enum ushort Command = 0x0085;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Stops transmitting tone started by mfglibStartTone().
struct EZSP_MfglibStopTone {
    enum ushort Command = 0x0086;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Starts transmitting a random stream of characters. This is so that the radio modulation can be measured.
struct EZSP_MfglibStartStream {
    enum ushort Command = 0x0087;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Stops transmitting a random stream of characters started by mfglibStartStream().
struct EZSP_MfglibStopStream {
    enum ushort Command = 0x0088;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Sends a single packet consisting of the following bytes: packetLength, packetContents[0], ... , packetContents[packetLength - 3], CRC[0], CRC[1]. The total number of bytes sent is packetLength + 1. The radio replaces the last two bytes of packetContents[] with the 16-bit CRC for the packet.
struct EZSP_MfglibSendPacket {
    enum ushort Command = 0x0089;
    struct Request {
        ubyte packetLength; // The length of the packetContents parameter in bytes. Must be greater than 3 and less than 123.
        ubyte[] packetContents; // The packet to send. The last two bytes will be replaced with the 16-bit CRC.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Sets the radio channel. Calibration occurs if this is the first time the channel has been used.
struct EZSP_MfglibSetChannel {
    enum ushort Command = 0x008A;
    struct Request {
        ubyte channel; // The channel to switch to. Valid values are 11 to 26.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Returns the current radio channel, as previously set via mfglibSetChannel().
struct EZSP_MfglibGetChannel {
    enum ushort Command = 0x008B;
    struct Request {
    }
    struct Response {
        ubyte channel; // The current channel.
    }
}

// First select the transmit power mode, and then include a method for selecting the radio transmit power. The valid power settings depend upon the specific radio in use. Ember radios have discrete power settings, and then requested power is rounded to a valid power setting; the actual power output is available to the caller via mfglibGetPower().
struct EZSP_MfglibSetPower {
    enum ushort Command = 0x008C;
    struct Request {
        ushort txPowerMode; // Power mode. Refer to txPowerModes in stack/include/ember-types.h for possible values.
        ubyte power; // Power in units of dBm. Refer to radio data sheet for valid range.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Returns the current radio power setting, as previously set via mfglibSetPower().
struct EZSP_MfglibGetPower {
    enum ushort Command = 0x008D;
    struct Request {
    }
    struct Response {
        ubyte power; // Power in units of dBm. Refer to radio data sheet for valid range.
    }
}

// A callback indicating a packet with a valid CRC has been received.
struct EZSP_MfglibRxHandler {
    enum ushort Command = 0x008E;
    struct Request {
    }
    struct Response {
        ubyte linkQuality; // The link quality observed during the reception
        byte rssi; // The energy level (in units of dBm) observed during the reception.
        ubyte packetLength; // The length of the packetContents parameter in bytes. Will be greater than 3 and less than 123.
        ubyte[] packetContents; // The received packet (last 2 bytes are not FCS / CRC and may be discarded).
    }
}


// # Bootloader Frames

// Quits the current application and launches the standalone bootloader (if installed) The function returns an error if the standalone bootloader is not present
struct EZSP_LaunchStandaloneBootloader {
    enum ushort Command = 0x008F;
    struct Request {
        ubyte mode; // Controls the mode in which the standalone bootloader will run. See the app. note for full details. Options are: STANDALONE_BOOTLOADER_NORMAL_MODE: Will listen for an over-the-air image transfer on the current channel with current power settings. STANDALONE_BOOTLOADER_RECOVERY_MODE: Will listen for an over-the-air image transfer on the default channel with default power settings. Both modes also allow an image transfer to begin with XMODEM over the serial protocol's Bootloader Frame.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Transmits the given bootload message to a neighboring node using a specific 802.15.4 header that allows the EmberZNet stack as well as the bootloader to recognize the message, but will not interfere with other ZigBee stacks.
struct EZSP_SendBootloadMessage {
    enum ushort Command = 0x0090;
    struct Request {
        bool broadcast; // If true, the destination address and pan id are both set to the broadcast address.
        EmberEUI64 destEui64; // The EUI64 of the target node. Ignored if the broadcast field is set to true.
        ubyte messageLength; // The length of the messageContents parameter in bytes.
        ubyte[] messageContents; // The multicast message.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Detects if the standalone bootloader is installed, and if so returns the installed version. If not return 0xffff. A returned version of 0x1234 would indicate version 1.2 build 34. Also return the node's version of PLAT, MICRO and PHY.
struct EZSP_GetStandaloneBootloaderVersionPlatMicroPhy {
    enum ushort Command = 0x0091;
    struct Request {
    }
    struct Response {
        ushort bootloader_version; // BOOTLOADER_INVALID_VERSION if the standalone bootloader is not present, or the version of the installed standalone bootloader.
        ubyte nodePlat; // The value of PLAT on the node
        ubyte nodeMicro; // The value of MICRO on the node
        ubyte nodePhy; // The value of PHY on the node
    }
}

// A callback invoked by the EmberZNet stack when a bootload message is received.
struct EZSP_IncomingBootloadMessageHandler {
    enum ushort Command = 0x0092;
    struct Request {
    }
    struct Response {
        EmberEUI64 longId; // The EUI64 of the sending node.
        ubyte lastHopLqi; // The link quality from the node that last relayed the message.
        byte lastHopRssi; // The energy level (in units of dBm) observed during the reception.
        ubyte messageLength; // The length of the messageContents parameter in bytes.
        ubyte[] messageContents; // The bootload message that was sent.
    }
}

// A callback invoked by the EmberZNet stack when the MAC has finished transmitting a bootload message.
struct EZSP_BootloadTransmitCompleteHandler {
    enum ushort Command = 0x0093;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value of EMBER_SUCCESS if an ACK was received from the destination or EMBER_DELIVERY_FAILED if no ACK was received.
        ubyte messageLength; // The length of the messageContents parameter in bytes.
        ubyte[] messageContents; // The message that was sent.
    }
}

// Perform AES encryption on plaintext using key.
struct EZSP_AesEncrypt {
    enum ushort Command = 0x0094;
    struct Request {
        ubyte[16] plaintext; // 16 bytes of plaintext.
        ubyte[16] key; // The 16-byte encryption key to use.
    }
    struct Response {
        ubyte[16] ciphertext; // 16 bytes of ciphertext.
    }
}

// A bootloader method for selecting the radio channel. This routine only works for sending and receiving bootload packets. Does not correctly do ZigBee stack changes. NOTE: this API is not safe to call on multi-network devices and it will return failure when so. Use of the ember/ezspSetRadioChannel APIs are multi-network safe and are recommended instead.
struct EZSP_OverrideCurrentChannel {
    enum ushort Command = 0x0095;
    struct Request {
        ubyte channel; // The channel to switch to. Valid values are 11 to 26.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}


// # ZLL Frames

// A consolidation of ZLL network operations with similar signatures; specifically, forming and joining networks or touch-linking.
struct EZSP_ZllNetworkOps {
    enum ushort Command = 0x00B2;
    struct Request {
        EmberZllNetwork networkInfo; // Information about the network.
        EzspZllNetworkOperation op; // Operation indicator.
        byte radioTxPower; // Radio transmission power.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// This call will cause the device to setup the security information used in its network. It must be called prior to forming, starting, or joining a network.
struct EZSP_ZllSetInitialSecurityState {
    enum ushort Command = 0x00B3;
    struct Request {
        EmberKeyData networkKey; // ZLL Network key.
        EmberZllInitialSecurityState securityState; // Initial security state of the network.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// This call will update ZLL security token information. Unlike emberZllSetInitialSecurityState, this can be called while a network is already established.
struct EZSP_ZllSetSecurityStateWithoutKey {
    enum ushort Command = 0x00CF;
    struct Request {
        EmberZllInitialSecurityState securityState; // Security state of the network.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// This call will initiate a ZLL network scan on all the specified channels.
struct EZSP_ZllStartScan {
    enum ushort Command = 0x00B4;
    struct Request {
        uint channelMask; // The range of channels to scan.
        byte radioPowerForScan; // The radio output power used for the scan requests.
        EmberNodeType nodeType; // The node type of the local device.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// This call will change the mode of the radio so that the receiver is on for a specified amount of time when the device is idle.
struct EZSP_ZllSetRxOnWhenIdle {
    enum ushort Command = 0x00B5;
    struct Request {
        uint durationMs; // The duration in milliseconds to leave the radio on.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// This call is fired when a ZLL network scan finds a ZLL network.
struct EZSP_ZllNetworkFoundHandler {
    enum ushort Command = 0x00B6;
    struct Request {
    }
    struct Response {
        EmberZllNetwork networkInfo; // Information about the network.
        bool isDeviceInfoNull; // Used to interpret deviceInfo field.
        EmberZllDeviceInfoRecord deviceInfo; // Device specific information.
        ubyte lastHopLqi; // The link quality from the node that last relayed the message.
        byte lastHopRssi; // The energy level (in units of dBm) observed during reception.
    }
}

// This call is fired when a ZLL network scan is complete.
struct EZSP_ZllScanCompleteHandler {
    enum ushort Command = 0x00B7;
    struct Request {
    }
    struct Response {
        EmberStatus status; // Status of the operation.
    }
}

// This call is fired when network and group addresses are assigned to a remote mode in a network start or network join request.
struct EZSP_ZllAddressAssignmentHandler {
    enum ushort Command = 0x00B8;
    struct Request {
    }
    struct Response {
        EmberZllAddressAssignment addressInfo; // Address assignment information.
        ubyte lastHopLqi; // The link quality from the node that last relayed the message.
        byte lastHopRssi; // The energy level (in units of dBm) observed during reception.
    }
}

// This call is fired when the device is a target of a touch link.
struct EZSP_ZllTouchLinkTargetHandler {
    enum ushort Command = 0x00BB;
    struct Request {
    }
    struct Response {
        EmberZllNetwork networkInfo; // Information about the network.
    }
}

// Get the ZLL tokens.
struct EZSP_ZllGetTokens {
    enum ushort Command = 0x00BC;
    struct Request {
    }
    struct Response {
        EmberTokTypeStackZllData data; // Data token return value.
        EmberTokTypeStackZllSecurity security; // Security token return value.
    }
}

// Set the ZLL data token.
struct EZSP_ZllSetDataToken {
    enum ushort Command = 0x00BD;
    struct Request {
        EmberTokTypeStackZllData data; // Data token to be set.
    }
    struct Response {
    }
}

// Set the ZLL data token bitmask to reflect the ZLL network state.
struct EZSP_ZllSetNonZllNetwork {
    enum ushort Command = 0x00BF;
    struct Request {
    }
    struct Response {
    }
}

// Is this a ZLL network?
struct EZSP_IsZllNetwork {
    enum ushort Command = 0x00BE;
    struct Request {
    }
    struct Response {
        bool isZllNetwork; // ZLL network?
    }
}

// This call sets the radio's default idle power mode.
struct EZSP_ZllSetRadioIdleMode {
    enum ushort Command = 0x00D4;
    struct Request {
        EmberRadioPowerMode mode; // The power mode to be set.
    }
    struct Response {
    }
}

// This call sets the default node type for a factory new ZLL device.
struct EZSP_ZllSetNodeType {
    enum ushort Command = 0x00D5;
    struct Request {
        EmberNodeType nodeType; // The node type to be set.
    }
    struct Response {
    }
}

// This call sets additional capability bits in the ZLL state.
struct EZSP_ZllSetAdditionalState {
    enum ushort Command = 0x00D6;
    struct Request {
        ushort state; // A mask with the bits to be set or cleared.
    }
    struct Response {
    }
}

// Is there a ZLL (Touchlink) operation in progress?
struct EZSP_ZllOperationInProgress {
    enum ushort Command = 0x00D7;
    struct Request {
    }
    struct Response {
        bool zllOperationInProgress; // ZLL operation in progress?
    }
}

// Is the ZLL radio on when idle mode active?
struct EZSP_ZllRxOnWhenIdleGetActive {
    enum ushort Command = 0x00D8;
    struct Request {
    }
    struct Response {
        bool zllRxOnWhenIdleGetActive; // ZLL radio on when idle mode active?
    }
}

// Get the primary ZLL (touchlink) channel mask.
struct EZSP_GetZllPrimaryChannelMask {
    enum ushort Command = 0x00D9;
    struct Request {
    }
    struct Response {
        uint zllPrimaryChannelMask; // The primary ZLL channel mask
    }
}

// Get the secondary ZLL (touchlink) channel mask.
struct EZSP_GetZllSecondaryChannelMask {
    enum ushort Command = 0x00DA;
    struct Request {
    }
    struct Response {
        uint zllSecondaryChannelMask; // The secondary ZLL channel mask
    }
}

// Set the primary ZLL (touchlink) channel mask
struct EZSP_SetZllPrimaryChannelMask {
    enum ushort Command = 0x00DB;
    struct Request {
        uint zllPrimaryChannelMask; // The primary ZLL channel mask
    }
    struct Response {
    }
}

// Set the secondary ZLL (touchlink) channel mask.
struct EZSP_SetZllSecondaryChannelMask {
    enum ushort Command = 0x00DC;
    struct Request {
        uint zllSecondaryChannelMask; // The secondary ZLL channel mask
    }
    struct Response {
    }
}

// Clear ZLL stack tokens.
struct EZSP_ZllClearTokens {
    enum ushort Command = 0x0025;
    struct Request {
    }
    struct Response {
    }
}


// # WWAH Frames

// Sets whether to use parent classification when processing beacons during a join or rejoin. Parent classification considers whether a received beacon indicates trust center connectivity and long uptime on the network
struct EZSP_SetParentClassificationEnabled {
    enum ushort Command = 0x00E7;
    struct Request {
        bool enabled; // Enable or disable parent classification
    }
    struct Response {
    }
}

// Gets whether to use parent classification when processing beacons during a join or rejoin. Parent classification considers whether a received beacon indicates trust center connectivity and long uptime on the network
struct EZSP_GetParentClassificationEnabled {
    enum ushort Command = 0x00F0;
    struct Request {
    }
    struct Response {
        bool enabled; // Enable or disable parent classification
    }
}

// sets the device uptime to be long or short
struct EZSP_SetLongUpTime {
    enum ushort Command = 0x00E3;
    struct Request {
        bool hasLongUpTime; // if the uptime is long or not
    }
    struct Response {
    }
}

// sets the hub connectivity to be true or false
struct EZSP_SetHubConnectivity {
    enum ushort Command = 0x00E4;
    struct Request {
        bool connected; // if the hub is connected or not
    }
    struct Response {
    }
}

// checks if the device uptime is long or short
struct EZSP_IsUpTimeLong {
    enum ushort Command = 0x00E5;
    struct Request {
    }
    struct Response {
        bool hasLongUpTime; // if the uptime is long or not
    }
}


// # Green Power Frames

// checks if the hub is connected or not
struct EZSP_IsHubConnected {
    enum ushort Command = 0x00E6;
    struct Request {
    }
    struct Response {
        bool isHubConnected; // if the hub is connected or not
    }
}

// Update the GP Proxy table based on a GP pairing.
struct EZSP_GpProxyTableProcessGpPairing {
    enum ushort Command = 0x00C9;
    struct Request {
        uint options; // The options field of the GP Pairing command.
        EmberGpAddress addr; // The target GPD.
        ubyte commMode; // The communication mode of the GP Sink.
        ushort sinkNetworkAddress; // The network address of the GP Sink.
        ushort sinkGroupId; // The group ID of the GP Sink.
        ushort assignedAlias; // The alias assigned to the GPD.
        ubyte[8] sinkIeeeAddress; // The IEEE address of the GP Sink.
        EmberKeyData gpdKey; // The key to use for the target GPD.
        uint gpdSecurityFrameCounter; // The GPD security frame counter.
        ubyte forwardingRadius; // The forwarding radius.
    }
    struct Response {
        bool gpPairingAdded; // Whether a GP Pairing has been created or not.
    }
}

// Adds/removes an entry from the GP Tx Queue.
struct EZSP_DGpSend {
    enum ushort Command = 0x00C6;
    struct Request {
        bool action; // The action to perform on the GP TX queue (true to add, false to remove).
        bool useCca; // Whether to use ClearChannelAssessment when transmitting the GPDF.
        EmberGpAddress addr; // The Address of the destination GPD.
        ubyte gpdCommandId; // The GPD command ID to send.
        ubyte gpdAsduLength; // The length of the GP command payload.
        ubyte[] gpdAsdu; // The GP command payload.
        ubyte gpepHandle; // The handle to refer to the GPDF.
        ushort gpTxQueueEntryLifetimeMs; // How long to keep the GPDF in the TX Queue.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// A callback to the GP endpoint to indicate the result of the GPDF transmission.
struct EZSP_DGpSentHandler {
    enum ushort Command = 0x00C7;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        ubyte gpepHandle; // The handle of the GPDF.
    }
}

// A callback invoked by the ZigBee GP stack when a GPDF is received.
struct EZSP_GpepIncomingMessageHandler {
    enum ushort Command = 0x00C5;
    struct Request {
    }
    struct Response {
        EmberStatus status; // The status of the GPDF receive.
        ubyte gpdLink; // The gpdLink value of the received GPDF.
        ubyte sequenceNumber; // The GPDF sequence number.
        EmberGpAddress addr; // The address of the source GPD.
        EmberGpSecurityLevel gpdfSecurityLevel; // The security level of the received GPDF.
        EmberGpKeyType gpdfSecurityKeyType; // The securityKeyType used to decrypt/authenticate the incoming GPDF.
        bool autoCommissioning; // Whether the incoming GPDF had the auto-commissioning bit set.
        ubyte bidirectionalInfo; // Bidirectional information represented in bitfields, where bit0 holds the rxAfterTx of incoming gpdf and bit1 holds if tx queue is available for outgoing gpdf.
        uint gpdSecurityFrameCounter; // The security frame counter of the incoming GDPF.
        ubyte gpdCommandId; // The gpdCommandId of the incoming GPDF.
        uint mic; // The received MIC of the GPDF.
        ubyte proxyTableIndex; // The proxy table index of the corresponding proxy table entry to the incoming GPDF.
        ubyte gpdCommandPayloadLength; // The length of the GPD command payload.
        ubyte[] gpdCommandPayload; // The GPD command payload.
    }
}

// Retrieves the proxy table entry stored at the passed index.
struct EZSP_GpProxyTableGetEntry {
    enum ushort Command = 0x00C8;
    struct Request {
        ubyte proxyIndex; // The index of the requested proxy table entry.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        EmberGpProxyTableEntry entry; // An EmberGpProxyTableEntry struct containing a copy of the requested proxy entry.
    }
}

// Finds the index of the passed address in the gp table.
struct EZSP_GpProxyTableLookup {
    enum ushort Command = 0x00C0;
    struct Request {
        EmberGpAddress addr; // The address to search for
    }
    struct Response {
        ubyte index; // The index, or 0x00FF for not found
    }
}

// Retrieves the sink table entry stored at the passed index.
struct EZSP_GpSinkTableGetEntry {
    enum ushort Command = 0x00DD;
    struct Request {
        ubyte sinkIndex; // The index of the requested sink table entry.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        EmberGpSinkTableEntry entry; // An EmberGpSinkTableEntry struct containing a copy of the requested sink entry.
    }
}

// Finds the index of the passed address in the gp table.
struct EZSP_GpSinkTableLookup {
    enum ushort Command = 0x00DE;
    struct Request {
        EmberGpAddress addr; // The address to search for.
    }
    struct Response {
        ubyte index; // The index, or 0xFF for not found
    }
}

// Retrieves the sink table entry stored at the passed index.
struct EZSP_GpSinkTableSetEntry {
    enum ushort Command = 0x00DF;
    struct Request {
        ubyte sinkIndex; // The index of the requested sink table entry.
        EmberGpSinkTableEntry entry; // An EmberGpSinkTableEntry struct containing a copy of the sink entry to be updated.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Removes the sink table entry stored at the passed index.
struct EZSP_GpSinkTableRemoveEntry {
    enum ushort Command = 0x00E0;
    struct Request {
        ubyte sinkIndex; // The index of the requested sink table entry.
    }
    struct Response {
    }
}

// Finds or allocates a sink entry
struct EZSP_GpSinkTableFindOrAllocateEntry {
    enum ushort Command = 0x00E1;
    struct Request {
        EmberGpAddress addr; // An EmberGpAddress struct containing a copy of the gpd address to be found.
    }
    struct Response {
        ubyte index; // An index of found or allocated sink or 0xFF if failed.
    }
}

// Clear the entire sink table
struct EZSP_GpSinkTableClearAll {
    enum ushort Command = 0x00E2;
    struct Request {
    }
    struct Response {
    }
}

// Initializes Sink Table
struct EZSP_GpSinkTableInit {
    enum ushort Command = 0x0070;
    struct Request {
    }
    struct Response {
    }
}

// Sets security framecounter in the sink table
struct EZSP_GpSinkTableSetSecurityFrameCounter {
    enum ushort Command = 0x00F5;
    struct Request {
        ubyte index; // Index to the Sink table
        uint sfc; // Security Frame Counter
    }
    struct Response {
    }
}

// Puts the GPS in commissioning mode.
struct EZSP_GpSinkCommission {
    enum ushort Command = 0x010A;
    struct Request {
        ubyte options; // commissioning options
        ushort gpmAddrForSecurity; // gpm address for security.
        ushort gpmAddrForPairing; // gpm address for pairing.
        ubyte sinkEndpoint; // sink endpoint.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Clears all entries within the translation table.
struct EZSP_GpTranslationTableClear {
    enum ushort Command = 0x010B;
    struct Request {
    }
    struct Response {
    }
}


// # Token Interface Frames

// Return number of active entries in sink table.
struct EZSP_GpSinkTableGetNumberOfActiveEntries {
    enum ushort Command = 0x0118;
    struct Request {
    }
    struct Response {
        uint number_of_entries; // Number of active entries in sink table.
    }
}

// Gets the total number of tokens.
struct EZSP_GetTokenCount {
    enum ushort Command = 0x0100;
    struct Request {
    }
    struct Response {
        ubyte count; // Total number of tokens.
    }
}

// Gets the token information for a single token at provided index
struct EZSP_GetTokenInfo {
    enum ushort Command = 0x0101;
    struct Request {
        ubyte index; // Index of the token in the token table for which information is needed.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        EmberTokenInfo tokenInfo; // Token information.
    }
}

// Gets the token data for a single token with provided key
struct EZSP_GetTokenData {
    enum ushort Command = 0x0102;
    struct Request {
        uint token; // Key of the token in the token table for which data is needed.
        uint index; // Index in case of the indexed token.
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
        EmberTokenData tokenData; // Token Data
    }
}

// Sets the token data for a single token with provided key
struct EZSP_SetTokenData {
    enum ushort Command = 0x0103;
    struct Request {
        uint token; // Key of the token in the token table for which data is to be set.
        uint index; // Index in case of the indexed token.
        EmberTokenData tokenData; // Token Data
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Reset the node by calling halReboot.
struct EZSP_ResetNode {
    enum ushort Command = 0x0104;
    struct Request {
    }
    struct Response {
    }
}

// Run GP security test vectors.
struct EZSP_GpSecurityTestVectors {
    enum ushort Command = 0x0117;
    struct Request {
    }
    struct Response {
        EmberStatus status; // An EmberStatus value indicating success or the reason for failure.
    }
}

// Factory reset all configured Zigbee tokens.
struct EZSP_TokenFactoryReset {
    enum ushort Command = 0x0077;
    struct Request {
        bool excludeOutgoingFC; // Exclude network and APS outgoing frame counter tokens.
        bool excludeBootCounter; // Exclude stack boot counter token.
    }
    struct Response {
    }
}
