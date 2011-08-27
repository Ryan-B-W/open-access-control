#include <WProgram.h>


extern void setup();
extern void loop();


int main(int, char**)
{
    // Mandatory init
    init();

    setup();

    while(true)
       loop();

    // never returns
    return 0;
}




#include <stdint.h>
#include <Wire.h>         // Needed for I2C Connection to the DS1307 date/time chip
#include <EEPROM.h>       // Needed for saving to non-voilatile memory on the Arduino.
#include <avr/pgmspace.h> // Allows data to be stored in FLASH instead of RAM
#include <DS1307.h>       // DS1307 RTC Clock/Date/Time chip library
#include <WIEGAND26.h>    // Wiegand 26 reader format libary
#include <PCATTACH.h>     // Pcint.h implementation, allows for >2 software interupts.


void setup();
void loop();
void runCommand(long command);
void alarmState(uint8_t alarmLevel);
void chirpAlarm(uint8_t chirps);
uint8_t pollAlarm(uint8_t input);
void trainAlarm();
void armAlarm(uint8_t level);
int checkSuperuser(long input);
void doorUnlock(int input);
void doorLock(int input);
void lockall();
void PROGMEMprintln(const prog_uchar str[]);
void PROGMEMprint(const prog_uchar str[]);
void logDate();
void logReboot();
void logChime();
void logTagPresent (long user, uint8_t reader);
void logAccessGranted(long user, uint8_t reader);
void logAccessDenied(long user, uint8_t reader);
void logkeypadCommand(uint8_t reader, long command);
void logalarmSensor(uint8_t zone);
void logalarmTriggered();
void logunLock(long user, uint8_t door);
void logalarmState(uint8_t level);
void logalarmArmed(uint8_t level);
void logprivFail();
void hardwareTest(long iterations);
void clearUsers();
void addUser(int userNum, uint8_t userMask, unsigned long tagNumber);
void deleteUser(int userNum);
int checkUser(unsigned long tagNumber);
void dumpUser(uint8_t usernum);
void readCommand();
void callReader1Zero();
void callReader1One();
void callReader2Zero();
void callReader2One();
void callReader3Zero();
void callReader3One();

#include "Open_Access_Control.pde"

