// Read-only diagnostic: never selects a slot or sends SetDevicePropValue.
#include "wpd_camera.h"
#include <iostream>
#include <iomanip>
#include <stdexcept>

int main() {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(initialized)) return 2;
  int exitCode = 0;
  try {
    const auto devices = WpdCamera::Discover();
    std::cout << "Fujifilm WPD cameras: " << devices.size() << std::endl;
    if (devices.size() != 1) throw std::runtime_error("Connect exactly one Fujifilm camera for this probe");
    WpdCamera camera; camera.Open(devices.front().id);
    std::cout << "WPD session opened using the inbox driver" << std::endl;
    for (const auto opcode : {0x1001, 0x1015, 0x1014}) {
      const auto reply = camera.Command(static_cast<uint16_t>(opcode), opcode == 0x1001 ? std::vector<uint32_t>{} : std::vector<uint32_t>{0xd18c});
      std::cout << "PTP 0x" << std::hex << opcode << " response 0x" << reply.code << std::dec << " data_bytes=" << reply.data.size() << std::endl;
      if (opcode == 0x1015 && reply.data.size() == 2) std::cout << "Current slot: " << (reply.data[0] | (reply.data[1] << 8)) << std::endl;
      if (reply.code != 0x2001) throw std::runtime_error("Camera rejected read-only probe. Check camera USB mode.");
    }
    camera.Close();
    std::cout << "PASS: discovery, session, device info and recipe-slot reads. No settings written." << std::endl;
  } catch (const std::exception& e) { std::cerr << e.what() << std::endl; exitCode = 1; }
  CoUninitialize();
  return exitCode;
}
