// Read-only diagnostic: never selects a slot or sends SetDevicePropValue.
#include "wpd_camera.h"
#include <iostream>
#include <iomanip>
#include <stdexcept>

struct Reader {
  const std::vector<uint8_t>& data; size_t offset=0;
  uint8_t U8() {return data.at(offset++);}
  uint16_t U16() {const auto a=U8();return static_cast<uint16_t>(a|(U8()<<8));}
  uint32_t U32() {const auto a=U16();return a|(static_cast<uint32_t>(U16())<<16);}
  std::string String() {const auto count=U8();std::string s;for(unsigned i=0;i<count;i++){const auto c=U16();if(c)s.push_back(c<128?static_cast<char>(c):'?');}return s;}
  std::vector<uint16_t> Array() {const auto count=U32();if(count>65536)throw std::runtime_error("Invalid array");std::vector<uint16_t> a;for(uint32_t i=0;i<count;i++)a.push_back(U16());return a;}
};

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
    const auto info=camera.Command(0x1001,{});
    if(info.code!=0x2001)throw std::runtime_error("GetDeviceInfo failed");
    Reader r{info.data};r.U16();r.U32();r.U16();r.String();r.U16();
    const auto ops=r.Array();r.Array();const auto props=r.Array();r.Array();r.Array();
    const auto maker=r.String(),model=r.String(),firmware=r.String();
    std::cout<<maker<<" "<<model<<" firmware "<<firmware<<std::endl;
    std::cout<<"Operations:";for(const auto op:ops)std::cout<<" "<<std::hex<<op;std::cout<<std::dec<<std::endl;
    std::cout<<"Recipe properties:";for(const auto prop:props)if(prop>=0xd18c&&prop<=0xd1a5)std::cout<<" "<<std::hex<<prop;std::cout<<std::dec<<std::endl;
    bool readable=true;
    for(const uint32_t prop:{0xd18cu,0xd18du,0xd192u,0xd191u,0xd198u,0xd1a2u}) {
      for(const uint16_t opcode:{static_cast<uint16_t>(0x1015),static_cast<uint16_t>(0x1014)}) {
        const auto reply=camera.Command(opcode,{prop});
        std::cout<<"PTP 0x"<<std::hex<<opcode<<" prop 0x"<<prop<<" response 0x"<<reply.code<<std::dec<<" data_bytes="<<reply.data.size();
        if(opcode==0x1015&&reply.data.size()==2)std::cout<<" value="<<(reply.data[0]|(reply.data[1]<<8));
        std::cout<<std::endl;
        if(opcode==0x1015&&reply.code!=0x2001)readable=false;
      }
    }
    camera.Close();
    if(!readable)throw std::runtime_error("Some property reads failed");
    std::cout << "PASS: discovery, session, device info and recipe-slot reads. No settings written." << std::endl;
  } catch (const std::exception& e) { std::cerr << e.what() << std::endl; exitCode = 1; }
  CoUninitialize();
  return exitCode;
}
