
project( Arduino )
cmake_minimum_required(VERSION 2.8)

set(target_name open_access_control)

set(CMAKE_MODULE_PATH "~/CMakeModules" ${CMAKE_MODULE_PATH})

set(ARDUINO_PLATFORM uno)
find_package(Arduino REQUIRED EEPROM Wire)

include_directories(${ARDUINO_INCLUDE_DIR})
include_directories(./libraries/DS1307  ./libraries/PCATTACH  ./libraries/Wiegand26)
file(GLOB_RECURSE cpp_ Open_Access_Control/*.cpp ./libraries/*.cpp)
add_executable(${target_name} ${cpp_})
target_link_libraries(${target_name}
  ${ARDUINO_LIBS}
)


generate_arduino_flash(${target_name})

