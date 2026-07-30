module driver.boards.smartevse.hardware;

version (SmartEVSE):

import urt.driver.adc;
import urt.driver.adc_sampler;
import urt.driver.gpio_interlock;
import urt.driver.pwm;
import urt.result : Result;

nothrow @nogc:


enum uint control_pilot_samples = 25;

struct SmartEVSEHardwareConfig
{
    uint pilot_output_gpio;
    ubyte pilot_adc_channel;
    ubyte proximity_adc_channel;
    ubyte temperature_adc_channel;
    uint residual_current_gpio;
    uint contactor1_gpio;
    uint contactor2_gpio;
}

struct SmartEVSEHardware
{
    Pwm pilot_pwm;
    Adc adc;
    AdcInput pilot_input;
    AdcInput proximity_input;
    AdcInput temperature_input;
    AdcSampler pilot_sampler;
    GpioInterlock residual_current_interlock;
    ushort[control_pilot_samples] pilot_ring;
}

Result hardware_open(ref SmartEVSEHardware hardware,
                     ref const SmartEVSEHardwareConfig config)
{
    GpioInterlockConfig interlock_config;
    PwmConfig pwm_config;
    AdcConfig adc_config;
    AdcInputConfig input_config;
    AdcSamplerConfig sampler_config;

    interlock_config.input.line = config.residual_current_gpio;
    interlock_config.output[0].line = config.contactor1_gpio;
    interlock_config.output[1].line = config.contactor2_gpio;
    interlock_config.safe_level[0] = false;
    interlock_config.safe_level[1] = false;
    interlock_config.output_count = 2;
    interlock_config.active_high = true;
    Result result = gpio_interlock_open(
        hardware.residual_current_interlock, 0, interlock_config);
    if (!result)
        return result;

    pwm_config.gpio = config.pilot_output_gpio;
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
    result = adc_input_open(hardware.adc, hardware.pilot_input,
                            input_config);
    if (!result)
        goto failed;

    input_config.channel = config.proximity_adc_channel;
    input_config.attenuation = AdcAttenuation.db6;
    result = adc_input_open(hardware.adc, hardware.proximity_input,
                            input_config);
    if (!result)
        goto failed;

    input_config.channel = config.temperature_adc_channel;
    result = adc_input_open(hardware.adc, hardware.temperature_input,
                            input_config);
    if (!result)
        goto failed;

    sampler_config.trigger.line = config.pilot_output_gpio;
    sampler_config.timer_resolution_hz = 1_000_000;
    result = adc_sampler_open(
        hardware.pilot_sampler, 0, hardware.adc, hardware.pilot_input,
        hardware.pilot_ring[], sampler_config);
    if (!result)
        goto failed;

    result = adc_sampler_schedule(hardware.pilot_sampler, 1000,
                                  AdcSampleTrigger.periodic);
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

Result pilot_sample_periodically(ref SmartEVSEHardware hardware,
                                 uint microseconds)
{
    return adc_sampler_schedule(hardware.pilot_sampler, microseconds,
                                AdcSampleTrigger.periodic);
}

Result pilot_sample_after_rising_edge(ref SmartEVSEHardware hardware,
                                      uint microseconds)
{
    return adc_sampler_schedule(hardware.pilot_sampler, microseconds,
                                AdcSampleTrigger.gpio_rising);
}

uint pilot_snapshot(ref SmartEVSEHardware hardware, ushort[] samples)
{
    return adc_sampler_snapshot(hardware.pilot_sampler, samples);
}

uint pilot_sample_mv(ref const SmartEVSEHardware hardware, uint raw)
{
    uint millivolts;
    return adc_raw_to_mv(hardware.pilot_input, raw, millivolts)
        ? millivolts : 0;
}

uint proximity_mv(ref SmartEVSEHardware hardware)
{
    uint millivolts;
    return adc_read_mv(hardware.adc, hardware.proximity_input, millivolts)
        ? millivolts : 0;
}

uint temperature_mv(ref SmartEVSEHardware hardware)
{
    uint millivolts;
    return adc_read_mv(hardware.adc, hardware.temperature_input, millivolts)
        ? millivolts : 0;
}

AdcCalibrationSource adc_calibration_source(
    ref const SmartEVSEHardware hardware)
{
    return hardware.pilot_input.calibration_source;
}

bool residual_current_fault_latched(
    ref const SmartEVSEHardware hardware)
{
    return gpio_interlock_fault_latched(
        hardware.residual_current_interlock);
}

Result residual_current_clear(ref SmartEVSEHardware hardware)
{
    return gpio_interlock_clear(hardware.residual_current_interlock);
}

void hardware_close(ref SmartEVSEHardware hardware)
{
    adc_sampler_close(hardware.pilot_sampler);
    adc_input_close(hardware.temperature_input);
    adc_input_close(hardware.proximity_input);
    adc_input_close(hardware.pilot_input);
    adc_close(hardware.adc);
    pwm_close(hardware.pilot_pwm);
    gpio_interlock_close(hardware.residual_current_interlock);
}
