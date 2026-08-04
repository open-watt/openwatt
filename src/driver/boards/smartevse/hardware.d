module driver.boards.smartevse.hardware;

version (SmartEVSE):

import urt.atomic : MemoryOrder, atomicLoad, atomicStore;
import urt.attribute : critical, isr_safe;
import urt.driver.adc;
import urt.driver.counter;
import urt.driver.gpio;
import urt.driver.event;
import urt.driver.pwm;
import urt.result : Result;

import driver.boards.smartevse.pins : RCMFAULT, SSR1, SSR2;

nothrow @nogc:


enum uint control_pilot_samples = 25;

// Residual current trip: RCM fault edge drops both contactors from the
// reflex tier (a true NMI on classic ESP32), so the response cannot be
// deferred by a critical section or a wedged scheduler. The state machine
// learns of the trip by polling residual_current_fired().
alias RcmReflex = ReflexGraph!(
    Reflex!(gpio_event(GpioLine(0, RCMFAULT), GpioInterruptTrigger.rising),
            gpio_task(GpioLine(0, SSR1), false),
            gpio_task(GpioLine(0, SSR2), false)));

struct SmartEVSEHardwareConfig
{
    uint pilot_output_gpio;
    ubyte pilot_adc_channel;
    ubyte proximity_adc_channel;
    ubyte temperature_adc_channel;
}

struct SmartEVSEHardware
{
    Pwm pilot_pwm;
    Adc adc;
    AdcInput pilot_input;
    AdcInput proximity_input;
    AdcInput temperature_input;
    Counter pilot_counter;
    Link edge_link;
    Link alarm_link;
    uint pilot_output_gpio;
    ushort[control_pilot_samples] pilot_ring = void;
    shared uint pilot_total;
    uint pilot_sample_count;
}

Result hardware_open(ref SmartEVSEHardware hardware, ref const SmartEVSEHardwareConfig config)
{
    PwmConfig pwm_config;
    AdcConfig adc_config;
    AdcInputConfig input_config;
    CounterConfig counter_config;

    hardware.pilot_pwm.port = ubyte.max;
    hardware.adc.unit = ubyte.max;
    hardware.pilot_input.channel = ubyte.max;
    hardware.pilot_input.calibration_source = AdcCalibrationSource.unavailable;
    hardware.proximity_input.channel = ubyte.max;
    hardware.proximity_input.calibration_source = AdcCalibrationSource.unavailable;
    hardware.temperature_input.channel = ubyte.max;
    hardware.temperature_input.calibration_source = AdcCalibrationSource.unavailable;
    hardware.pilot_counter.port = ubyte.max;
    hardware.edge_link.slot = ubyte.max;
    hardware.alarm_link.slot = ubyte.max;

    hardware.pilot_ring[] = 0;
    hardware.pilot_total = 0;
    hardware.pilot_sample_count = 0;

    Result result = RcmReflex.open();
    if (!result)
        return result;

    pwm_config.output.line = config.pilot_output_gpio;
    pwm_config.frequency = 1000;
    pwm_config.period = 1024;
    pwm_config.initial_duty = 1024;
    result = pwm_open(hardware.pilot_pwm, 0, pwm_config);
    if (!result)
        goto failed;

    adc_config.unit = 0;
    result = adc_open(hardware.adc, adc_config);
    if (!result)
        goto failed;

    input_config.channel = config.pilot_adc_channel;
    input_config.attenuation = AdcAttenuation.db12;
    input_config.bit_width = 10;
    input_config.default_reference_mv = 1100;
    result = adc_input_open(hardware.adc, hardware.pilot_input, input_config);
    if (!result)
        goto failed;

    input_config.channel = config.proximity_adc_channel;
    input_config.attenuation = AdcAttenuation.db6;
    result = adc_input_open(hardware.adc, hardware.proximity_input, input_config);
    if (!result)
        goto failed;

    input_config.channel = config.temperature_adc_channel;
    result = adc_input_open(hardware.adc, hardware.temperature_input, input_config);
    if (!result)
        goto failed;

    hardware.pilot_output_gpio = config.pilot_output_gpio;
    counter_config.resolution_hz = 1_000_000;
    result = counter_open(hardware.pilot_counter, 0, counter_config);
    if (!result)
        goto failed;

    result = link_open(hardware.alarm_link, 1, counter_event(hardware.pilot_counter), isr_task!pilot_alarm(&hardware));
    if (!result)
        goto failed;

    result = pilot_sample_periodically(hardware, 1000);
    if (!result)
        goto failed;
    return Result.success;

failed:
    hardware_close(hardware);
    return result;
}

Result pilot_set_duty(ref SmartEVSEHardware hardware, uint duty)
{
    return pwm_set_duty(hardware.pilot_pwm, duty);
}

Result pilot_sample_periodically(ref SmartEVSEHardware hardware, uint microseconds)
{
    if (hardware.edge_link.is_open)
        link_close(hardware.edge_link);
    return counter_arm(hardware.pilot_counter, microseconds, true);
}

Result pilot_sample_after_rising_edge(ref SmartEVSEHardware hardware, uint microseconds)
{
    Result result = counter_arm(hardware.pilot_counter, microseconds, false);
    if (!result)
        return result;
    if (hardware.edge_link.is_open)
        return Result.success;
    EventSource edge = gpio_event(GpioLine(0, hardware.pilot_output_gpio), GpioInterruptTrigger.rising);
    return link_open(hardware.edge_link, 0, edge, counter_task(hardware.pilot_counter));
}

// Copies oldest-first; the ring is single-writer from the sampling interrupt,
// so a count-stable double read stands in for a lock.
uint pilot_snapshot(ref SmartEVSEHardware hardware, ushort[] samples)
{
    ushort[control_pilot_samples] copy = void;
    uint total, check;
    do
    {
        total = atomicLoad!(MemoryOrder.acquire)(hardware.pilot_total);
        copy = hardware.pilot_ring;
        check = atomicLoad!(MemoryOrder.acquire)(hardware.pilot_total);
    }
    while (total != check);

    uint valid = total < control_pilot_samples ? total : control_pilot_samples;
    uint start = total >= control_pilot_samples ? total % control_pilot_samples : 0;
    uint count;
    for (; count < valid && count < samples.length; ++count)
        samples[count] = copy[(start + count) % control_pilot_samples];
    hardware.pilot_sample_count = total;
    return count;
}

uint pilot_sample_mv(ref const SmartEVSEHardware hardware, uint raw)
{
    uint millivolts;
    return adc_raw_to_mv(hardware.pilot_input, raw, millivolts) ? millivolts : 0;
}

uint proximity_mv(ref SmartEVSEHardware hardware)
{
    uint millivolts;
    return adc_read_mv(hardware.adc, hardware.proximity_input, millivolts) ? millivolts : 0;
}

uint temperature_mv(ref SmartEVSEHardware hardware)
{
    uint millivolts;
    return adc_read_mv(hardware.adc, hardware.temperature_input, millivolts) ? millivolts : 0;
}

AdcCalibrationSource adc_calibration_source(ref const SmartEVSEHardware hardware)
{
    return hardware.pilot_input.calibration_source;
}

// Nonzero when the reflex has tripped since the last poll. Read-and-clear.
uint residual_current_fired(ref SmartEVSEHardware)
{
    return RcmReflex.fired();
}

void hardware_close(ref SmartEVSEHardware hardware)
{
    link_close(hardware.edge_link);
    link_close(hardware.alarm_link);
    counter_close(hardware.pilot_counter);
    adc_input_close(hardware.temperature_input);
    adc_input_close(hardware.proximity_input);
    adc_input_close(hardware.pilot_input);
    adc_close(hardware.adc);
    pwm_close(hardware.pilot_pwm);
    RcmReflex.close();
}


private:

@isr_safe @critical bool pilot_alarm(void* context, LinkContext)
{
    SmartEVSEHardware* hardware = cast(SmartEVSEHardware*)context;
    uint raw;
    if (!adc_read_critical(hardware.adc, hardware.pilot_input, raw))
        return false;
    uint total = atomicLoad!(MemoryOrder.relaxed)(hardware.pilot_total);
    hardware.pilot_ring[total % control_pilot_samples] = raw & 0xffff;
    atomicStore!(MemoryOrder.release)(hardware.pilot_total, total + 1);
    return false;
}
