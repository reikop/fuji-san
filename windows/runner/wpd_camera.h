#pragma once
#include <windows.h>
#include <portabledeviceapi.h>
#include <wrl/client.h>
#include <cstdint>
#include <string>
#include <vector>

struct WpdCameraDevice { std::wstring id; std::wstring name; };
struct WpdReply {
  uint16_t code = 0;
  std::vector<uint8_t> data;
  std::vector<uint32_t> params;
};
class WpdCamera {
 public:
  static std::vector<WpdCameraDevice> Discover();
  void Open(const std::wstring& id);
  void Close();
  bool IsOpen() const { return device_ != nullptr; }
  WpdReply Command(uint16_t opcode, const std::vector<uint32_t>& params,
                   const std::vector<uint8_t>* outgoing = nullptr);
 private:
  Microsoft::WRL::ComPtr<IPortableDevice> device_;
};
