/*
;    Project: Smart EVSE v4
;
;
; Permission is hereby granted, free of charge, to any person obtaining a copy
; of this software and associated documentation files (the "Software"), to deal
; in the Software without restriction, including without limitation the rights
; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
; copies of the Software, and to permit persons to whom the Software is
; furnished to do so, subject to the following conditions:
;
; The above copyright notice and this permission notice shall be included in
; all copies or substantial portions of the Software.
;
; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
; THE SOFTWARE.
*/

module driver.boards.smartevse.evse;

version (SmartEVSE):

import urt.driver.gpio;

nothrow @nogc:
extern(C):

alias uint8_t = ubyte;
alias uint16_t = ushort;
alias uint32_t = uint;
alias int8_t = byte;
alias int16_t = short;
alias int32_t = int;
alias SmartEVSECaptureCallback = extern(C) bool function(uint16_t, uint16_t, uint16_t) nothrow @nogc;

enum NUM_ADC_SAMPLES = 32;
enum CIRCULARBUFFER = 256;     // Must be a power of 2
enum uint32_t PWM_5 = 50;
enum uint32_t PWM_95 = 950;
enum uint32_t PWM_100 = 1000;

enum uint32_t PP_IN = 34;
enum uint32_t CP_IN = 39;
enum uint32_t TEMP = 36;
enum uint32_t SSR1 = 32;
enum uint32_t SSR2 = 27;
enum uint32_t RCMFAULT = 13;
enum uint32_t CP_OUT = 19;
enum uint32_t CPOFF = 15;

enum uint8_t DISABLE = 0;
enum uint8_t ENABLE = 1;

// USART Circular buffers
struct CircularBuffer
{
    char[CIRCULARBUFFER] buffer;
    uint16_t head;
    uint16_t tail;
}

uint8_t LockCable = 0;

uint32_t elapsedtime, elapsedmax=0;

// the following variables are used in interrupts
//
__gshared uint16_t[NUM_ADC_SAMPLES] ADC_CP;      // CP pin samples
__gshared uint16_t[NUM_ADC_SAMPLES] ADC_PP;      // PP pin samples
__gshared uint16_t[NUM_ADC_SAMPLES] ADC_Temp;    // Temperature samples
__gshared uint8_t ADCidx = 0;                    // index in sample buffers
__gshared uint16_t MainsCycleTime = 0;           // mains cycle time (20ms for 50Hz) Convert to Hz : 10000 / (MainsCycleTime/100))
__gshared uint8_t PowerPanicFlag = 0;
uint8_t PowerPanicEnabled = 0;
uint8_t RCmonEnabled = 0;
uint8_t ModemPowered = 0;

uint8_t[256] RxBuffer2;                         // USART2 Receive buffer

uint8_t RxRdy1 = 0;
uint8_t RxIdx2 = 0;
uint8_t ModbusRxLen = 0;
//uint32_t ModbusTimer = 0;
__gshared uint8_t DmaBusy = 0;

// Circular buffers for USART1 and TX of USART2
CircularBuffer RxBuffer;                        // USART1 Receive buffer ESP.WCH
CircularBuffer TxBuffer;                        // USART1 Transmit ringbuffer WCH.ESP (DMA)
CircularBuffer ModbusTx;                        // USART2 Transmit buffer (modbus)

int ow_smartevse_pwm_init(int pin);
void ow_smartevse_pwm_set(uint32_t duty);
int ow_smartevse_capture_init(int cp_output_pin, SmartEVSECaptureCallback callback);
void ow_smartevse_capture_set_alarm(uint32_t microseconds, int auto_reload);
void ow_smartevse_capture_shutdown(int cp_output_pin);


// -------------------------- Interrupt Handlers ---------------------------------

bool ADC1_2_IRQHandler(uint16_t cp, uint16_t pp, uint16_t temperature)
{
    ADC_CP[ADCidx] = cast(uint16_t)(cast(uint32_t)cp * 3300 / 4095);
    ADC_PP[ADCidx] = cast(uint16_t)(cast(uint32_t)pp * 2200 / 4095);
    ADC_Temp[ADCidx++] = cast(uint16_t)(cast(uint32_t)temperature * 2200 / 4095);
    if (ADCidx == NUM_ADC_SAMPLES) ADCidx = 0;
    return false;
}


void DMA1_Channel4_IRQHandler()
{
    DmaBusy = 0;                                // Flag DMA ready for more data

    if (TxBuffer.head != TxBuffer.tail) {       // Check if more data needs to be sent
        uart_start_dma_transfer();
    }
}


void TIM2_IRQHandler()
{
    if (RxIdx2) {
        ModbusRxLen = RxIdx2;               // Flag to main loop that we received modbus data
        RxIdx2 = 0;
    }
}


void TIM4_IRQHandler()
{
    // Counter counted to 65 mS and overflowed.
    // At 50Hz line frequency we normally expect 3 cycles in 65mS (1 cycle = 20mS)
    // So we most likely lost power. As there is still power left in the PSU and 10mF cap,
    // we shutdown the ESP32 and QCA modem, and unlock the charging cable (if locked)
    PowerPanicFlag = 1;
}

// Residual current monitor fault trigger.
//
void EXTI9_5_IRQHandler()
{
    // The ActiveObject performs the second level check on the application
    // thread before forwarding the RCM fault to the control state machine.
}

// Serial comm interrupt handler between WCH and ESP
// FUNCONF_UART_PRINTF_BAUD bps
void USART1_IRQHandler()
{
    // OpenWatt's SerialStream owns the UART ISR and forwards complete data.
}


// Serial comm interrupt handler RS485, also handle modbus t1.5 and t3.5 timeouts
// 9600 bps
void USART2_IRQHandler()
{
    // OpenWatt's SerialStream owns the UART ISR and Modbus framing timeout.
}


// --------------------------- END of ISR's -------------------------------------------
/*
// Function to check if the buffer is full
uint8_t buffer_full(CircularBuffer *cb) {
    //return (((cb.head + 1) % sizeof(cb.buffer)) == cb.tail);
    return (((cb.head + 1) & 0xff ) == cb.tail);
}
*/

// Function to add an element to the buffer
uint8_t buffer_enqueue(CircularBuffer *cb, char data) {
    if ( ((cb.head + 1) & (CIRCULARBUFFER - 1) ) == cb.tail ) {
        return 0; // Buffer is full
    }
    cb.buffer[cb.head] = data;
    cb.head = (cb.head + 1) & (CIRCULARBUFFER - 1);
    return 1;
}


// Function to remove an element from the buffer
uint8_t buffer_dequeue(CircularBuffer *cb, char *data) {
    if (cb.head == cb.tail) {
        return 0; // Buffer is empty
    }
    *data = cb.buffer[cb.tail];
    cb.tail = (cb.tail + 1) & (CIRCULARBUFFER - 1);
    return 1;
}


void PowerPanicCtrl(uint8_t enable)
{
    if (enable) {
        PowerPanicEnabled = 1;
    } else {
        PowerPanicEnabled = 0;
    }
}


void RCmonCtrl(uint8_t enable)
{
    if (enable) {
        RCmonEnabled = 1;
    } else {
        RCmonEnabled = 0;
    }
}

void ModemPower(uint8_t enable)
{
    ModemPowered = enable;
}


// test RCMON
// enable test signal to RCM14-03 sensor. Should trigger the fault output
void testRCMON() {
    // SmartEVSE v3.0 exposes only the RCM fault output to this ESP32.
}


//============================ Peripheral Init Functions ==============================
//



void GPIOInit()
{
    gpio_input_init(PP_IN);
    gpio_input_init(CP_IN);
    gpio_input_init(TEMP);
    gpio_output_init(CP_OUT, true);
    gpio_output_init(CPOFF, true);
    gpio_output_init(SSR1, false);
    gpio_output_init(SSR2, false);
    gpio_input_init(RCMFAULT, Pull.up);
}


void UsartInit()
{
    // OpenWatt owns the ESP32 UARTs through SerialStream instances.
}


void DMAInit()
{
    // OpenWatt's ESP32 UART bridge owns DMA and completion delivery.
}


void TIM1Init()
{
    // The ESP32 GPTimer starts in State A, sampling once per millisecond.
    ow_smartevse_capture_set_alarm(PWM_100, 1);
}


// Timer used for Modbus timeout
void TIM2Init()
{
    // Modbus RTU framing timeouts are owned by OpenWatt's ModbusInterface.
}


void TIM3Init()
{
    // RGB indication is a separate OpenWatt board concern.
}

// Timer 4 is set up to monitor the ZC(CH3) input.
// On each mains cycle the Timer 4 interrupt handler is called
// It's also called when the counter overflows (loss of mains)
void TIM4Init()
{
    // SmartEVSE v3.0 does not route the mains zero-cross signal to the ESP32.
}


// External interrupt on the PB9 / RCMFAULT input
//
void EXTInit()
{
    // RCMFAULT is checked by the ActiveObject on each 10 ms control event.
}


/*
 * initialize ADC
 */
void ADCInit()
{
    // ADC1 channels 3, 6 and 0 are configured by the ESP-IDF capture bridge.
}

// ------------------------------------- END of INIT functions -------------------------------------

// Read the Temperature sensor data.
// Range -50 - +125 C
//
int8_t TemperatureSensor() {
    uint32_t TempAvg = 0;
    uint8_t n;
    int8_t Temperature;
    static int8_t Old_Temperature = -128;

    for(n=0; n<NUM_ADC_SAMPLES; n++) TempAvg += ADC_Temp[n];
    TempAvg = TempAvg / NUM_ADC_SAMPLES ;


    // The MCP9700A temperature sensor outputs 500mV at 0C, and has a 10mV/C change in output voltage.
    // 750mV is 25C, 400mV = -10C
    // The ESP32 bridge stores calibrated millivolts.
    Temperature = cast(int8_t)((cast(int32_t)TempAvg - 500) / 10);
    if (Temperature != Old_Temperature)
        Old_Temperature = Temperature;
    return Temperature;
}


// Read the Proximity Pin data, and determine the maximum current the cable can handle.
//
uint8_t ProximityPin() {
    uint32_t PPAvg = 0;
    uint8_t n, MaxCap;

    for(n=0; n<NUM_ADC_SAMPLES; n++) PPAvg += ADC_PP[n];
    PPAvg = PPAvg / NUM_ADC_SAMPLES ;

    MaxCap = 13;                                                   // No resistor, Max cable current = 13A
    if ((PPAvg > 1300) && (PPAvg < 1800)) MaxCap = 16;             // Max cable current = 16A  680R . should be around 1.3V
    if ((PPAvg > 600) && (PPAvg < 900)) MaxCap = 32;               // Max cable current = 32A  220R . should be around 0.6V
    if ((PPAvg > 200) && (PPAvg < 500)) MaxCap = 63;               // Max cable current = 63A  100R . should be around 0.3V

    return MaxCap;
}


// Copy data to circular buffer
// return nr of bytes written
// Note! Can't use printf here, as it's used by write_
int buffer_write(CircularBuffer *cb, char *data, uint16_t size)
{
    uint16_t i;
    for (i = 0; i < size; i++) {
        if(!buffer_enqueue(cb, data[i])) return 0;      // Buffer full?
    }

    return i; // Number of bytes written
}

// Called by _write, putchar and DMA ISR
void uart_start_dma_transfer()
{
    if (DmaBusy == 0 && TxBuffer.head != TxBuffer.tail) {
        DmaBusy = 1;
        TxBuffer.tail = TxBuffer.head;
        DmaBusy = 0;
    }
}



// Used by printf as std output
//
int _write(int fd, const char *buffer, int size)
{
    int ret = buffer_write(&TxBuffer, cast(char*)buffer, cast(uint16_t)size);
    if (ret) uart_start_dma_transfer();
    return ret;
}

// used by printf when only one character is sent
//
int putchar(int c)
{
    int ret = buffer_enqueue(&TxBuffer, cast(char)c);
    if (ret) uart_start_dma_transfer();
    return ret;
}


uint8_t ReadESPdata(char *buf) {
    uint8_t i = 0;
    while (buffer_dequeue(&RxBuffer, &buf[i])) {
        i++;
    }
    return i; // Return the number of bytes read
}


int setup(SmartEVSECaptureCallback callback) {
    GPIOInit();
    UsartInit();                                    // Usart1 = FUNCONF_UART_PRINTF_BAUD bps. Usart2 = Modbus 9600bps 8N1
    DMAInit();                                      // DMA transfer for Uart1 TX

    gpio_output_set(CPOFF, true);                   // CP disabled
    gpio_output_set(SSR1, false);                   // Contactor 1 OFF
    gpio_output_set(SSR2, false);                   // Contactor 2 OFF

    if (ow_smartevse_pwm_init(cast(int)CP_OUT) != 0)
        return -1;
    if (ow_smartevse_capture_init(cast(int)CP_OUT, callback) != 0)
        return -1;

    EXTInit();                                      // Interrupt on RCMFAULT pin
    ADCInit();                                      // CP, PP and Temp inputs
    TIM1Init();                                     // Timebase for CP (PWM)signal and CP/PP/Temp ADC reading (1kHz)
    TIM2Init();                                     // Modbus t3.5 timeout timer, calls ISR after 3.5ms of silence on the bus
    TIM3Init();                                     // LED PWM ~4Khz
    TIM4Init();                                     // ZC input monitoring 50Hz

    ModemPower(1);
    RCmonCtrl(DISABLE);
    PowerPanicCtrl(DISABLE);
    return 0;
}


// Delay in milliseconds
// We don't reset SysTick counter, but instead set the SysTick compare register
void delay(uint32_t ms) {
    // Blocking delays are not used by the OpenWatt port. The ActiveObject
    // schedules any delayed continuation on the application timer queue.
}

void hardware_shutdown()
{
    ow_smartevse_capture_shutdown(cast(int)CP_OUT);
    gpio_output_set(SSR1, false);
    gpio_output_set(SSR2, false);
    gpio_output_set(CPOFF, true);
}


// SmartEVSE-3/src/main.cpp control section. Function order and state-machine
// flow follow the pinned upstream source; product/UI/load-balancing decisions
// are supplied by the hard control functions in this section.

enum uint8_t STATE_A = 0;
enum uint8_t STATE_B = 1;
enum uint8_t STATE_C = 2;
enum uint8_t STATE_B1 = 9;
enum uint8_t STATE_C1 = 10;

enum uint8_t PILOT_12V = 12;
enum uint8_t PILOT_9V = 9;
enum uint8_t PILOT_6V = 6;
enum uint8_t PILOT_3V = 3;
enum uint8_t PILOT_DIODE = 1;
enum uint8_t PILOT_NOK = 0;
enum uint8_t PILOT_SHORT = 255;

enum uint16_t MIN_CURRENT = 6;
enum uint16_t MAX_CURRENT = 800;

uint8_t State = STATE_A;
uint16_t ChargeCurrent = MIN_CURRENT * 10;
uint32_t CurrentPWM = 1024;
bool Contactor1;
bool Contactor2;
bool AccessStatus;
bool RCMFault;
uint8_t MaxCapacity = 13;
uint8_t MinCurrent = MIN_CURRENT;
uint8_t MaxCurrent = 80;
uint8_t ChargeDelay;
uint8_t C1Timer;
uint8_t PilotDisconnectTime;
bool PilotDisconnected;


uint16_t GetCurrent() {
    uint32_t DutyCycle = CurrentPWM;

    if (DutyCycle < 102) {
        return 0; //PWM off or ISO15118 modem enabled
    } else if (DutyCycle < 870) {
        return cast(uint16_t)((DutyCycle * 1000 / 1024) * 6 / 10 + 1);
    } else if (DutyCycle <= 983) {
        return cast(uint16_t)(((DutyCycle * 1000 / 1024)- 640) * 25 / 10 + 3);
    } else {
        return 0; //constant +12V
    }
}


// Write duty cycle to pin
// Value in range 0 (0% duty) to 1024 (100% duty) for ESP32, 1000 (100% duty) for CH32
void SetCPDuty(uint32_t DutyCycle){
    ow_smartevse_pwm_set(DutyCycle);                                       // update PWM signal
    CurrentPWM = DutyCycle;
}

// Set Charge Current
// Current in Amps * 10 (160 = 16A)
void SetCurrent(uint16_t current) {
    uint32_t DutyCycle;

    if ((current >= (MIN_CURRENT * 10)) && (current <= 510)) DutyCycle = current * 10 / 6;
                                                                            // calculate DutyCycle from current
    else if ((current > 510) && (current <= 800)) DutyCycle = (current * 10 / 25) + 640;
    else DutyCycle = 100;                                                   // invalid, use 6A
    DutyCycle = DutyCycle * 1024 / 1000;                                    // conversion to 1024 = 100%
    SetCPDuty(DutyCycle);
}


void setStatePowerUnavailable() {
    if (State == STATE_A)
       return;
    //State changes between A,B,C,D are caused by EV or by the user
    //State changes between x1 and x2 are created by the EVSE
    //State changes between x1 and x2 indicate availability (x2) of unavailability (x1) of power supply to the EV
    if (State == STATE_C) setState(STATE_C1);                       // If we are charging, tell EV to stop charging
    else if (State != STATE_C1 && State != STATE_B1) setState(STATE_B1);    // If we are not in State C1 or B1, switch to State B1
}


//this replaces old CP_OFF and CP_ON and PILOT_CONNECTED and PILOT_DISCONNECTED macros
//setPilot(true) switches the PILOT ON (CONNECT), setPilot(false) switches it OFF
void setPilot(bool On) {
    if (On) {
        gpio_output_set(CPOFF, false);
    } else
        gpio_output_set(CPOFF, true);
}


void setState(uint8_t NewState) {
    switch (NewState) {
        case STATE_B1:
            if (!ChargeDelay) ChargeDelay = 3;
            if (State != STATE_B1 && !PilotDisconnected && AccessStatus) {
                setPilot(false);
                PilotDisconnected = true;
                PilotDisconnectTime = 5;
            }
            goto case STATE_A;

        case STATE_A:
            gpio_output_set(SSR1, false);
            gpio_output_set(SSR2, false);
            Contactor1 = false;
            Contactor2 = false;
            SetCPDuty(1024);
            ow_smartevse_capture_set_alarm(PWM_100, 1);

            if (NewState == STATE_A) {
                ChargeDelay = 0;
                setPilot(true);
            }
            break;

        case STATE_B:
            setPilot(true);
            gpio_output_set(SSR1, false);
            gpio_output_set(SSR2, false);
            Contactor1 = false;
            Contactor2 = false;
            ow_smartevse_capture_set_alarm(PWM_95, 0);
            break;

        case STATE_C:
            gpio_output_set(SSR1, true);
            gpio_output_set(SSR2, true);
            Contactor1 = true;
            Contactor2 = true;
            break;

        case STATE_C1:
            SetCPDuty(1024);
            ow_smartevse_capture_set_alarm(PWM_100, 1);
            C1Timer = 6;
            ChargeDelay = 15;
            break;

        default:
            break;
    }

    State = NewState;
}


void setAccess(uint8_t Access) {
    AccessStatus = Access != 0;
    if (!AccessStatus) {
        if (State == STATE_C) setState(STATE_C1);
        else if (State != STATE_C1 && State == STATE_B) setState(STATE_B1);
    }
}


// Determine the state of the Pilot signal
//
uint8_t Pilot() {

    uint32_t sample, Min = 3300, Max = 0;
    uint32_t voltage;
    uint8_t n;

    // calculate Min/Max of last 25 CP measurements
    for (n=0 ; n<25 ;n++) {
        sample = ADC_CP[n];
        voltage = sample;
        if (voltage < Min) Min = voltage;                                   // store lowest value
        if (voltage > Max) Max = voltage;                                   // store highest value
    }

    // test Min/Max against fixed levels
    if (Min >= 3055 ) return PILOT_12V;                                     // Pilot at 12V (min 11.0V)
    if ((Min >= 2735) && (Max < 3055)) return PILOT_9V;                     // Pilot at 9V
    if ((Min >= 2400) && (Max < 2735)) return PILOT_6V;                     // Pilot at 6V
    if ((Min >= 2000) && (Max < 2400)) return PILOT_3V;                     // Pilot at 3V
    if ((Min >= 1600) && (Max < 2000)) return PILOT_SHORT;                  // Pilot short or open
    if ((Min > 100) && (Max < 300)) return PILOT_DIODE;                     // Diode Check OK
    return PILOT_NOK;                                                       // Pilot NOT ok
}


// Is there at least 6A available for a new EVSE?
// The first hard-function port has no load-balancing participants.
char IsCurrentAvailable() {
    return AccessStatus && !RCMFault;
}


void Timer1S_singlerun() {
    if (ChargeDelay)
        --ChargeDelay;
    if (PilotDisconnectTime && --PilotDisconnectTime == 0) {
        setPilot(true);
        PilotDisconnected = false;
    }
    if (State == STATE_C1 && C1Timer && --C1Timer == 0) {
        gpio_output_set(SSR1, false);
        gpio_output_set(SSR2, false);
        Contactor1 = false;
        Contactor2 = false;
        setState(STATE_B1);
    }
}


void Timer10ms_singlerun() {
    static uint8_t DiodeCheck = 0;
    static uint16_t StateTimer = 0;                                         // When switching from State B to C, make sure pilot is at 6v for 100ms
    uint8_t pilot = Pilot();

    // ############### EVSE State A #################

    if (State == STATE_A || State == STATE_B1) {
        // When the pilot line is disconnected, wait for PilotDisconnectTime, then reconnect
        if (PilotDisconnected) {
            if (PilotDisconnectTime == 0) {
                setPilot(true);
                PilotDisconnected = false;
            }
        } else if (pilot == PILOT_12V) {
            if (State != STATE_A) setState(STATE_A);
            ChargeDelay = 0;
        } else if (pilot == PILOT_9V && !RCMFault
            && ChargeDelay == 0 && AccessStatus)
        {
            DiodeCheck = 0;

            MaxCapacity = ProximityPin();
            if (MaxCurrent > MaxCapacity) ChargeCurrent = MaxCapacity * 10;
            else ChargeCurrent = MinCurrent * 10;

            if (IsCurrentAvailable()) {
                SetCurrent(ChargeCurrent);
                setState(STATE_B);
            }
        } else if (pilot == PILOT_9V && State != STATE_B1 && AccessStatus) {
            setState(STATE_B1);
        }
    }

    // ############### EVSE State B #################

    if (State == STATE_B) {

        if (pilot == PILOT_12V) {
            setState(STATE_A);

        } else if (pilot == PILOT_6V && ++StateTimer > 50) {
            if (DiodeCheck == 1 && !RCMFault && ChargeDelay == 0 && AccessStatus) {
                if (IsCurrentAvailable()) {
                    DiodeCheck = 0;
                    setState(STATE_C);
                }
            }

        // PILOT_9V
        } else if (pilot == PILOT_9V) {
            StateTimer = 0;
        }
        if (pilot == PILOT_DIODE) {
            DiodeCheck = 1;
            ow_smartevse_capture_set_alarm(PWM_5, 0);
        }
    }

    // ############### EVSE State C1 #################

    if (State == STATE_C1)
    {
        if (pilot == PILOT_12V)
        {
            setState(STATE_A);
        }
        else if (pilot == PILOT_9V)
        {
            setState(STATE_B1);
        }
    }

    // ############### EVSE State C #################

    if (State == STATE_C) {

        if (pilot == PILOT_12V) {
            setState(STATE_A);
        } else if (pilot == PILOT_9V) {
            setState(STATE_B);
            DiodeCheck = 0;
        } else if (pilot == PILOT_SHORT) {
            if (++StateTimer > 50) {
                StateTimer = 0;
                setState(STATE_B);
                DiodeCheck = 0;
            }

        } else StateTimer = 0;
    }

    // Residual current monitor active, and DC current > 6mA ?
    if (RCmonEnabled && RCMFault) {
        if (State) setState(STATE_B1);
    }
}


uint8_t CurrentState()
{
    return State;
}


void setRCMFault(bool fault)
{
    RCMFault = fault;
}
