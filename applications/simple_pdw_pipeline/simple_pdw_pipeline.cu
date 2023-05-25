#include <arpa/inet.h>
#include "holoscan/holoscan.hpp"
#include "basic_network_operator_rx.h"
#include "basic_network_operator_tx.h"
#include <cuda/std/complex>
#include "matx.h"

using namespace matx;
using ftype = float;
using ComplexType = cuda::std::complex<ftype>;


struct TaggedSignalData {
  TaggedSignalData(int _id,
      tensor_t<ComplexType, 1> _signal)
    : signal(_signal), id(_id) {}
  int id;
  tensor_t<ComplexType, 1> signal;
};

struct DetectedPulseSlice {
  DetectedPulseSlice(int _id,
      int _offset,
      int _zero_bin,
      tensor_t<ComplexType, 1> _signal,
      tensor_t<ftype, 1> _power)
    : signal(_signal), power(_power), zero_bin(_zero_bin), offset(_offset), id(_id) {}
  int id;
  int offset;
  int zero_bin;
  tensor_t<ftype, 1> power;
  tensor_t<ComplexType, 1> signal;
};

struct PulseDescription{
  PulseDescription(int _id,
      int _low,
      int _high,
      int _zero,
      float _max_amplitude,
      float _sum_power,
      float _average_amplitude):
    id(_id),
    low_bin(_low),
    high_bin(_high),
    zero_bin(_zero),
    max_amplitude(_max_amplitude),
    sum_power(_sum_power),
    average_amplitude(_average_amplitude) {}
  int id;
  int low_bin;
  int high_bin;
  int zero_bin;
  float max_amplitude;
  float sum_power;
  float average_amplitude;
};

const unsigned int burst_length = 7;

class PulsePrinterOp : public holoscan::Operator{
public:
  HOLOSCAN_OPERATOR_FORWARD_ARGS(PulsePrinterOp);
  PulsePrinterOp() = default;

  void setup(holoscan::OperatorSpec& spec) override{
    spec.input<PulseDescription>("pulse_description");
    spec.output<NetworkOpBurstParams>("burst_out");
    spec.param(sample_rate, "sample_rate", "Samples per second", "Sample rate in Hz.", {});
    spec.param(to_screen, "to_screen", "Print data to screen", "Print Data to screen", {});
    spec.param(to_tx, "to_tx", "Send Data through Tx", "Send data through Tx", {});
  }

  void compute(holoscan::InputContext& op_input, holoscan::OutputContext& op_output, holoscan::ExecutionContext&) override {
    auto data = op_input.receive<PulseDescription>("pulse_description");
    float resolution_mhz = (sample_rate.get() / (2e6 * data->zero_bin));
    float low_freq = (data->low_bin - data->zero_bin) * resolution_mhz ;
    float high_freq = (data->high_bin - data->zero_bin) * resolution_mhz;
    if (to_screen.get()) {
      std::cout << "Sum power " << data->sum_power << std::endl;
      std::cout << "Pulse started at " << low_freq << " MHz" << std::endl;
      std::cout << "Pulse end at " << high_freq << " MHz" << std::endl;
      std::cout << "Max power:" << data->max_amplitude << std::endl;
      std::cout << "Average amplitude " << data->average_amplitude << std::endl;
    }

    auto buff = new uint32_t[7];
    // Next, place these values into a network burst operator and send it
    if (to_tx.get()) {
      buff[0] = htonl((uint32_t)data->id);
      buff[1] = htonl((uint32_t)data->low_bin);
      buff[2] = htonl((uint32_t)data->high_bin);
      buff[3] = htonl((uint32_t)data->zero_bin);
      buff[4] = htonl((uint32_t)data->sum_power);
      buff[5] = htonl((uint32_t)data->max_amplitude);
      buff[6] = htonl((uint32_t)data->average_amplitude);
      auto out = std::make_shared<NetworkOpBurstParams>(
        (uint8_t*)buff,
        sizeof(uint32_t) * burst_length,
        1); 
      HOLOSCAN_LOG_INFO("Forwarding message to Network TX");
      op_output.emit(out, "burst_out");
    }
  }
  holoscan::Parameter<float> sample_rate;
  holoscan::Parameter<bool> to_screen;
  holoscan::Parameter<bool> to_tx;
};

class PulseDescriptorOp : public holoscan::Operator {
public:
  HOLOSCAN_OPERATOR_FORWARD_ARGS(PulseDescriptorOp);
  PulseDescriptorOp() = default;

  void setup(holoscan::OperatorSpec& spec) override{
    spec.input<DetectedPulseSlice>("detected_pulses");
    spec.output<PulseDescription>("pulse_description");
  }

  void compute(holoscan::InputContext& op_input, holoscan::OutputContext& op_output, holoscan::ExecutionContext&) override {
    auto data = op_input.receive<DetectedPulseSlice>("detected_pulses");
    tensor_t<float,0> sum_power{};
    tensor_t<float,0> maximum_power{};
    sum(sum_power, data->power,0);
    rmax(maximum_power, data->power,0);
    cudaStreamSynchronize(0);
    float average_amplitude = sum_power() / data->power.Size(0);
    auto out = std::make_shared<PulseDescription>(
        data->id,
        data->offset,
        data->offset + data->power.Size(0),
        data->zero_bin,
        maximum_power(),
        sum_power(),
        average_amplitude);
    op_output.emit(out, "pulse_description");
  }
};

class ThresholdingOp : public holoscan::Operator {
public:
  HOLOSCAN_OPERATOR_FORWARD_ARGS(ThresholdingOp);
  ThresholdingOp() = default;
  void setup(holoscan::OperatorSpec& spec) override{
    spec.input<TaggedSignalData>("fft_input");
    spec.output<DetectedPulseSlice>("detected_pulses");

    spec.param(threshold_param, "threshold", "Constant Threshold", "Samples greater than this threshold will trigger the detector", {});
    spec.param(max_pulse_count, "max_pulses", "Pulse Detection Limit", "The maximum number of pulses this detector can detect", {});
  }

  void compute(holoscan::InputContext& op_input, holoscan::OutputContext& op_output, holoscan::ExecutionContext&) override {
    auto data = op_input.receive<TaggedSignalData>("fft_input");
    auto thresh_mask = make_tensor<char>({data->signal.Size(0) + 1});
    tensor_t<float, 1> power = make_tensor<ftype>({data->signal.Size(0)});
    tensor_t<float, 0> threshold{};

    threshold() = threshold_param.get();

    (power = abs(data->signal)).run();
    //Prepend a zero so we can shift the data to test for rising and falling edges
    thresh_mask(0) = 0;
    (thresh_mask.Slice({1}, {data->signal.Size(0) + 1}) = (power > threshold)).run();

    tensor_t<int, 0> rising_edge_count{};
    tensor_t<int, 0> falling_edge_count{};

    auto rising_edges_index = make_tensor<unsigned int>({max_pulse_count.get()});
    auto falling_edges_index = make_tensor<unsigned int>({max_pulse_count.get()});

    auto right_shift = thresh_mask.Slice({0}, {data->signal.Size(0)});
    auto original = thresh_mask.Slice({1}, {data->signal.Size(0)+1});

    auto rising_edge_op = original && !right_shift;
    auto falling_edge_op = !original && right_shift;

    find_idx(rising_edges_index, rising_edge_count, rising_edge_op, GT{0});
    find_idx(falling_edges_index, falling_edge_count, falling_edge_op, GT{0});

    cudaStreamSynchronize(0);

    if(rising_edge_count() != falling_edge_count()){
      HOLOSCAN_LOG_INFO("RISING AND FALLING EDGE COUNTS DO NOT MATCH");
      for(int i=0;  i< rising_edge_count(); i++){
        std::cout << "Rising edge at " << rising_edges_index(i) << std::endl;
      }
      for(int i=0;  i< falling_edge_count(); i++){
        std::cout << "Falling edge at " << falling_edges_index(i) << std::endl;
      }
    } else {
      for(int i=0;  i< rising_edge_count(); i++){
        auto out = std::make_shared<DetectedPulseSlice>(
            data->id,
            rising_edges_index(i),
            //Falling edge is the index after the pulse since the slice is exclusive at the second
            //parameter this is correct.
            data->signal.Size(0) / 2,
            data->signal.Slice({rising_edges_index(i)}, {falling_edges_index(i)}),
            power.Slice({rising_edges_index(i)}, {falling_edges_index(i)}));
        op_output.emit(out, "detected_pulses");
      }
    }

  }

private:
  holoscan::Parameter<int64_t> threshold_param;
  holoscan::Parameter<uint32_t> max_pulse_count;
};


class FFTOp : public holoscan::Operator {
public:
  HOLOSCAN_OPERATOR_FORWARD_ARGS(FFTOp);
  FFTOp() = default;
  void setup(holoscan::OperatorSpec& spec) override{
    spec.input<TaggedSignalData>("signal_input");
    spec.output<TaggedSignalData>("fft_output");
  }

  void compute(holoscan::InputContext& op_input, holoscan::OutputContext& op_output, holoscan::ExecutionContext&) override {
    auto data = op_input.receive<TaggedSignalData>("signal_input");
    int size = data->signal.Size(0);
    auto shifted_fft = make_tensor<ComplexType, 1>({size});
    matx::fft(data->signal, data->signal);
    (data->signal = fftshift1D(data->signal)).run();
    op_output.emit(data, "fft_output");
  }
  
};

class SignalGeneratorOp : public holoscan::Operator {
public:
  HOLOSCAN_OPERATOR_FORWARD_ARGS(SignalGeneratorOp);
  SignalGeneratorOp() = default;

  void setup(holoscan::OperatorSpec& spec) override{
    spec.output<TaggedSignalData>("signal_output");
    spec.param(number_samples, "samples_per_packet", "Samples per Packet", "The number of samples in a single packet in this generator.", {});
    spec.param(sample_rate, "sample_rate", "Samples per second", "Sample rate in Hz.", {});
    spec.param(chirp_starting_frequency, "chirp_starting_frequency", "Starting frequency", "Chirp Starting Frequency", {});
    spec.param(chirp_stop_frequency, "chirp_stopping_frequency", "Stopping frequency", "Chirp Stop Frequency", {});
  }

  void initialize() override {
    HOLOSCAN_LOG_INFO("SignalGeneratorOp::initialize()");
    holoscan::Operator::initialize();
    id = 0;
  }

  void compute(holoscan::InputContext& op_input, holoscan::OutputContext& op_output, holoscan::ExecutionContext&) override {
    double chirp_duration = (1.0/sample_rate.get())*number_samples.get();
    auto chirp_op = cchirp({number_samples.get()},
        chirp_duration,
        chirp_starting_frequency.get(),
        chirp_duration,
        chirp_stop_frequency.get());
    auto chirp = make_tensor<ComplexType>({number_samples.get()});
    auto out = std::make_shared<TaggedSignalData>(id, chirp);
    (out->signal = chirp_op).run();

    op_output.emit(out, "signal_output");
    id++;
  }

  int id;
  holoscan::Parameter<int32_t> number_samples;
  holoscan::Parameter<float> sample_rate;
  holoscan::Parameter<float> chirp_starting_frequency;
  holoscan::Parameter<float> chirp_stop_frequency;
  
};

class PacketToTensorOp : public holoscan::Operator {
  public:
    HOLOSCAN_OPERATOR_FORWARD_ARGS(PacketToTensorOp);
    PacketToTensorOp() = default;

    void setup(holoscan::OperatorSpec& spec) override {
      spec.input<NetworkOpBurstParams>("burst_in");
      spec.output<TaggedSignalData>("tensor_output");
    }

    void initialize() override {
      HOLOSCAN_LOG_INFO("Converting incoming packet data to Complex Tensor data");
      holoscan::Operator::initialize();
    }

    void compute(holoscan::InputContext& op_input, holoscan::OutputContext& op_output, holoscan::ExecutionContext&) override {
      auto packet = op_input.receive<NetworkOpBurstParams>("burst_in");
      int id = (packet->data[0] << 8) | packet->data[1];  // Getting the first 16 bits of the packet
      packet->data = packet->data + 2;  // Go up 16 bits to get to the actual packet data
      matx::index_t size = (packet->len - sizeof(int16_t))/(sizeof(int16_t)* 2);
      auto nums = make_tensor<ComplexType>({size});
      int16_t* samples = (int16_t*)packet->data;
      for (int i = 0; i < size; i++) {
        nums(i) = ComplexType((int16_t)ntohs(samples[i*2]), (int16_t)ntohs(samples[i*2 + 1]));
      }
      auto out = std::make_shared<TaggedSignalData>(id, nums);
      op_output.emit(out, "tensor_output");
    }
};

class App : public holoscan::Application {
 public:
  void compose() override {
    using namespace holoscan;

    auto net_rx = make_operator<ops::BasicNetworkOpRx>("net_rx", from_config("network_rx"));
    auto convert = make_operator<PacketToTensorOp>("converter");
    auto fft = make_operator<FFTOp>("fft");
    auto thresh = make_operator<ThresholdingOp>("pulse_detector", from_config("pulse_detector"));
    auto descrip = make_operator<PulseDescriptorOp>("pulse_descriptor");
    auto printer = make_operator<PulsePrinterOp>("pulse_printer", from_config("printer"));
    auto net_tx = make_operator<ops::BasicNetworkOpTx>("net_tx", from_config("network_tx"));

    add_flow(net_rx, convert, {{"burst_out", "burst_in"}});
    add_flow(convert, fft, {{"tensor_output", "signal_input"}});
    add_flow(fft, thresh, {{"fft_output", "fft_input"}});
    add_flow(thresh, descrip, {{"detected_pulses", "detected_pulses"}});
    add_flow(descrip, printer, {{"pulse_description", "pulse_description"}});
    add_flow(printer, net_tx, {{"burst_out", "burst_in"}});
  }
};

int main(int argc, char** argv) {
  holoscan::load_env_log_level();

  auto app = holoscan::make_application<App>();

  // Get the configuration
  auto config_path = std::filesystem::canonical(argv[0]).parent_path();
  config_path += "/simple_pdw_pipeline.yaml";
  app->config(config_path);

  app->run();

  return 0;
}
