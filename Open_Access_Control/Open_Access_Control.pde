/*
 * Open Source RFID Access Controller
 *
 * 4/12/2010 v1.16
 * Arclight - arclight@23.org
 * Danozano - danozano@gmail.com
 *
 * Latest update fixes pin assignments to line up with new hardware design
 * 
 * This program interfaces the Arduino to RFID, PIN pad and all
 * other input devices using the Wiegand-26 Communications
 * Protocol. It is recommended that the keypad inputs be
 * opto-isolated in case a malicious user shorts out the 
 * input device.
 * Outputs go to an open-collector relay driver for magnetic door hardware.
 * Analog inputs are used for alarm sensor monitoring.  These should probably be
 * isolated as well, since many sensors use +12V.
 *
 */

/* Header files - stuff we're including
*/

#include <Wire.h>         //Needed for I2C Connection to the DS1307 date/time chip
#include <EEPROM.h>       //Needed for saving to non-voilatile memory on the Arduino.

#include <Ethernet.h>   //Ethernet stuff, comment out if not used.
#include <Server.h>
#include <Client.h>

#include <DS1307.h>      //DS1307 RTC Clock/Date/Time chip library
#include <WIEGAND26.h>   //Wiegand 26 reader format libary
#include <PCATTACH.h>    //Pcint.h implementation, allows for >2 software interupts.


/* User List
*/

#define queeg      111111               //Name and badge number in HEX
#define arclight   0x38E59D             //Be sure to update below.
#define kallahar   33333
#define danozano   0x3909D3
#define flea       55555
long  userList [] = {arclight,danozano,kallahar,queeg,flea};  //User access table (Move to flash later)

#define pinON      LOW                  // Low or high for on-off
#define pinOFF     HIGH

#define DOORDELAY 2500                  // How long to open door lock once access is granted. (2500 = 2.5s)
#define SENSORTHRESHOLD 100             // Voltage level (0-1024) at which an alarm zone is considered open.

#define EEPROM_ALARM 0                  // EEPROM address to store alarm state between reboots (0..511)
#define EEPROM_ALARMARMED 1             // EEPROM address to store alarm armed state between reboots
#define EEPROM_ALARMZONES 20            // Starting ddress to store "normal" analog values for alarm zone sensor reads.
#define KEYPADTIMEOUT 5000              // Timeout for pin pad entry.
                                        // Pins we're using to talk I2C protocol to the RTC
                                        // Analog input pin4 = I2C SDA
                                        // Analog input pin5 = I2C SCL



byte reader1Pins[]={2,3};               // Reader 1 connected to pins 4,5
byte reader2Pins[]= {4,5};              // Reader2 connected to pins 6,7
byte reader3Pins[]= {0,0};             // Reader3 connected to pins X,Y

const byte analogsensorPins[] = {0,1,2,3};  //Alarm Sensors connected to other analog pins
const byte alarmstrobePin= 8;                   // Strobe/pre-action pin
const byte alarmsirenPin = 9;                   // Siren/Alarm output pin
const byte alarmPins[]= {0,1,2,3};                  // Alarm sensor zones
const byte doorPin[]   = {6,7};                 // Door Open pins
const byte doorledPin[] = {8,8};                // Access Granted LEDs (optional) 



#define numUsers (sizeof(userList)/sizeof(long))                  //User access array size (used in later loops/etc)
#define NUMDOORS (sizeof(doorPin)/sizeof(byte))
#define numAlarmPins (sizeof(alarmPins)/sizeof(byte))

//Other global variables

byte second, minute, hour, dayOfWeek, dayOfMonth, month, year;   //RTC clock variables

byte alarmStatus = EEPROM.read(EEPROM_ALARM);                   // Read the last alarm state as saved in eeprom.
byte alarmArmed = EEPROM.read(EEPROM_ALARMARMED);               // Alarm level variable (0..5, 0==OFF) 


// Enable up to 3 door access readers.
volatile long reader1 = 0;
volatile int  reader1Count = 0;
volatile long reader2 = 0;
volatile int  reader2Count = 0;
volatile long reader3 = 0;
volatile int  reader3Count = 0;

/* Create an instance of the various C++ libraries we are using.
*/

  DS1307 ds1307;
  WIEGAND26 wiegand26;
  PCATTACH pcattach;
    


void setup(){

  
Wire.begin();   // start Wire library as I2C-Bus Master

/*
Attach pin change interrupt service routines from the Wiegand RFID readers
*/
pcattach.PCattachInterrupt(reader1Pins[0], callReader1Zero, CHANGE); 
pcattach.PCattachInterrupt(reader1Pins[1], callReader1One,  CHANGE);  
pcattach.PCattachInterrupt(reader2Pins[1], callReader2One,  CHANGE);
pcattach.PCattachInterrupt(reader2Pins[0], callReader2Zero, CHANGE);

  //Clear and initialize readers
  wiegand26.initReaderOne(); //Set up Reader 1 and clear buffers.
  wiegand26.initReaderTwo(); 

  //Initialize doors 
  
  for(byte i=0; i<NUMDOORS; i++){        
    pinMode(doorPin[i], OUTPUT);           //Sets the door output pins to output
    digitalWrite(doorPin[i], HIGH);        //Sets the door outputs to HIGH (DOOR LOCK)

    //  pinMode(doorledPin[i],  OUTPUT);       //Sets door LED pin to output 
    //  digitalWrite(doorledPin[], HIGH);      //Sets door LED output to HIGH (LED OFF)
  }
  //end doors init



  Serial.begin(57600);	               	       //Set up Serial output

  logReboot();
  chirpAlarm(8,alarmsirenPin);                 //Chirp the alarm 8 times to show system ready.
  //end other devices init
  wiegand26.initReaderOne();
}


void loop()
{                          // Main branch, runs over and over again



  // rfid polling is interrupt driven, just test for the reader1Count value to climb to the bit length of the key
  // change reader1Count & reader1 et. al. to arrays for loop handling of multiple reader output events
  // later change them for interrupt handling as well!
  // currently hardcoded for a single reader unit



  if(reader1Count >= 26){                            //  tag presented to reader1
    logTagPresent(reader1,1);                        //  write log entry to serial port
                                                     //  CHECK TAG IN OUR LIST OF USERS. -255 = no match
    if(checkAccess(reader1) == 1) {                  //  if > 0 there is a match. checkAccess (reader1) is the userList () index 
      logAccessGranted(reader1, 1);                  //  log and unlock door 1

        if(alarmArmed !=0){ 
        alarmArmed =0;
        alarmState(0,0);                                       // Deactivate Alarm if armed. (Must do this _before_unlockin door.
      }                                            

      doorUnlock(0);                                           // Unlock the door.
      wiegand26.initReaderOne();
      long keypadTime = 0;                                     // Timeout counter for  reader with key pad
      long keypadValue=0;
      keypadTime   = millis();              

      while((millis() - keypadTime)  <=KEYPADTIMEOUT){
                                                               // If access granted, open 5 second window for pin pad commands.
        if(reader1Count >=4){
          if(reader1 !=0xB){                         //Pin pad command can be any length, terminated with '#' ont he keypad.
            if(keypadValue ==0){             
              keypadValue = reader1; 
            }
            else if(keypadValue !=0) {
              keypadValue = keypadValue <<4;
              keypadValue |= reader1;               
            }
            wiegand26.initReaderOne();                         //Reset reader one and move on.
          } 


        }

      }
      if(keypadValue !=0){
        logkeypadCommand(1,keypadValue);
        runCommand(keypadValue);                              // Run any commands entered at the keypads.
        wiegand26.initReaderOne();
      }

    }
    else if(checkAccess(reader1) !=1) {           // If no user match, log entry written
      logAccessDenied(reader1,1);                 // no tickee, no laundree
    }
                                                           
    wiegand26.initReaderOne();

  }




  if(reader2Count >= 26){                           //  tag presented to reader2
    logTagPresent(reader2,2);                       //  write log entry to serial port

    if(checkAccess(reader2) == 1) {                // if > 0 there is a match. checkAccess (reader2) is the userList () index 
      logAccessGranted(reader2, 2);                // log and unlock door 1
      //  CHECK TAG IN OUR LIST OF USERS. -255 = no match
      if(alarmStatus !=0){
        alarmState(0,0);                                    //  Deactivate Alarm
      }
      doorUnlock(1);                                        //Unlock the door.



    }
    else if(checkAccess(reader2) !=1) {           //  no match, log entry written
      logAccessDenied(reader2,2);                 //  no tickee, no laundree
    }
    //  reset for next tag scan
    wiegand26.initReaderTwo();

  }



  /* Check physical sensors with 
     the logic below. Behavior is based on
     the current alarmArmed value.
     0=disarmed 
     1=armed
     2=
     3=
     4=door chime only (Check zone 0/chirp alarm if active)
 
 */
 
  switch(alarmArmed) {
  case 0:
    {
      break;                                        // Alarm is not armed, do nothing.  
    }
  case 1: 
    {                                               // Alarm is armed, check sensor zones.
      if(alarmStatus !=0){  
        for(byte i=0; i<=numAlarmPins; i++) {
          if(pollAlarm(i) !=0 ){
            alarmState(1,i);                        // If zone is tripped, immediately set AlarmStatus to 1 (alarm immediate).

          }
        }                                     
      } 
      break;  
    } 

  case 4: 
    {                 //Door chime mode
      if(pollAlarm(0) !=0) {
        chirpAlarm(10,alarmsirenPin);
        break;  
      }
    }

  default: 
    {
      break;  
    }
  }

}








  /* Check physical sensors with 
     the logic below. Behavior is based on
     the current alarmArmed value.
     0=disarmed 
     1=armed
     2=
     3=
     4=door chime only (Check zone 0/chirp alarm if active)
 
 */
 
void runCommand(long command) {         // Run any commands entered at the pin pad.

  switch(command) {                              

  case 0x0: 
    {                                   // If command = 0, do nothing
      break;
    }        

  case 0x1: 
    {                                     // If command = 1, deactivate alarm
      alarmState(0,0);                    // Set global alarm level variable
      armAlarm(0);
      chirpAlarm(2,doorledPin[0]);
      break;  
    }

  case 0x2: 
    {                                   // If command =2, activate alarm with delay.
      chirpAlarm(200,doorledPin[0]);                  // 200 chirps = ~30 seconds delay
      armAlarm(1);                    
      break; 
    }        
  case 0x3: 
    {
      armAlarm(4);                   // Set to door chime only
      chirpAlarm(3,doorledPin[0]);   
      break;  
    }
  case 0x4:
    {
      trainAlarm();                // Train the alarm sensors
      chirpAlarm(4,doorledPin[0]);
      break;
    }

  case 0x911: 
    {
      chirpAlarm(9,doorledPin[0]);
      armAlarm(1);                   // Emergency
      alarmState(1,254);
      break;  
    }


  default: 
    {       
      break;      
    }  
  }
}


/* Alarm System Functions - Modify these as needed for your application. 
 Sensor zones may be polled with digital or analog pins. Unique reader2
 resistors can be used to check more zones from the analog pins.
 */

byte alarmState(byte alarmLevel, byte alarmUnitNumber) {        //Changes the alarm status

  logalarmSensor(alarmUnitNumber);
  logalarmState(alarmLevel); 
  EEPROM.write(EEPROM_ALARM,alarmUnitNumber);  //Save the alarm state to eeprom
  switch (alarmLevel) {                              
  case 0: 
    {                                              // If alarmLevel == 0 turn off alarm.
      digitalWrite(alarmstrobePin, HIGH);         
      digitalWrite(alarmsirenPin, HIGH);
      alarmStatus = alarmLevel;                    //Set global alarm level variable
      break;  
    }        
  case 1: 
    {                                              // If alarmLevel == 1 turn on strobe lights (SENSOR TRIPPED)
      digitalWrite(alarmstrobePin, LOW);          //we would only activate a small LED if there was another output available. hint hint
      alarmStatus = alarmLevel;                    //Set global alarm level variable
      break;  
    }        
      
  case 2: 
    {
      digitalWrite(alarmsirenPin, LOW);          // If alarmLevel == 2 turn on strobe and siren (LOUD ALARM)
      digitalWrite(alarmstrobePin, LOW);      
      alarmStatus = alarmLevel;                    //Set global alarm level variable
      break;    
    }

    /*
      case 4: {
     vaporize_intruders(STUN);
     }
     
     case 5: {
     vaporize_intruders(MAIM);
     }  etc. etc. etc.
     */

  default: 
    {                                            //exceptional cases kill alarm outputs
      digitalWrite(alarmsirenPin, HIGH);         //      Turn off siren
      digitalWrite(alarmstrobePin, HIGH);        // and  Turn off strobe
    }  

  }

}  //End of alarmState()

void chirpAlarm(byte chirps, byte pin){            // Chirp the siren pin or strobe to indicate events.      
  for(byte i=0; i<=chirps; i++) {
    digitalWrite(pin, LOW);
    delay(100);
    digitalWrite(pin, HIGH);
    delay(200);                              
  }    
}                                   

byte pollAlarm(byte input){

  // Return 1 if sensor shows < pre-defined voltage.
  if(abs(analogRead(analogsensorPins[input]) - EEPROM.read(EEPROM_ALARMZONES+input)) >SENSORTHRESHOLD){

    return 1;

  }
  else return 0;
}

void trainAlarm(){                       //Train the system about the default states of the alarm pins.
  logtrainAlarm();
  for(byte i=0; i<=numAlarmPins; i++) {  //Save results to EEPROM
  EEPROM.write((EEPROM_ALARMZONES+i),analogRead(analogsensorPins[i])); 
  }
}

void armAlarm(byte level){                       //Arm the alarm and set to level
  alarmArmed = level;
  if(level != EEPROM.read(EEPROM_ALARMARMED)){ 
    EEPROM.write(EEPROM_ALARMARMED,level); 
  }
}


/* Access System Functions - Modify these as needed for your application. 
 These function control lock/unlock and user lookup.
 */

int checkAccess(long input){       //Check to see if user is in the user list. If yes, return their index value.
  for(int i=0; i<=numUsers; i++){   
    if(input == userList[i]){
      return(1);
    }
  }                   
  return -255;             //If no, return -255
}

int disableKey(long input){       //Set user key to negative value if we need to expire.
  for(int i=0; i<numUsers; i++){   
    if(userList[i] == input){
      userList[i] *= -1;
      return(1);
    }                                  
    else return -255;          
  }   //If not found, return -255
}


void doorUnlock(int input) {          //Send an unlock signal to the door and flash the Door LED
  digitalWrite(doorPin[input], LOW);
  //  digitalWrite(doorledPin, LOW);
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" unlocked");
  delay(DOORDELAY);
  digitalWrite(doorPin[input], HIGH);
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" relocked");
  //  digitalWrite(doorledPin, HIGH);
}


void lockall() {                      //Lock down all doors. Can also be run periodically to safeguard system.
  for(byte i=0; i<NUMDOORS; i++){
    digitalWrite(doorPin[i], HIGH);
    Serial.print("Door ");
    Serial.print(i,DEC);
    Serial.println(" locked");
  }
  // digitalWrite(doorledPin, HIGH);
}

/* Logging Functions - Modify these as needed for your application. 
 Logging may be serial to USB or via Ethernet (to be added later)
 */

void logDate()
{
  ds1307.getDateDs1307(&second, &minute, &hour, &dayOfWeek, &dayOfMonth, &month, &year);
  Serial.print(hour, DEC);
  Serial.print(":");
  Serial.print(minute, DEC);
  Serial.print(":");
  Serial.print(second, DEC);
  Serial.print("  ");
  Serial.print(month, DEC);
  Serial.print("/");
  Serial.print(dayOfMonth, DEC);
  Serial.print("/");
  Serial.print(year, DEC);
  Serial.print("  Day_of_week:");
  Serial.print(dayOfWeek, DEC);
  Serial.print(" ");
  
}

void logReboot() {                                  //Log system startup
  logDate();
  Serial.println("*** Access Control System Booted and initialized. ***");
}


void logTagPresent (long user, byte reader) {     //Log Tag Presented events
  logDate();
  Serial.print("User ");
  Serial.print(user,HEX);
  Serial.print(" presented tag at reader ");
  Serial.println(reader,DEC);
}

void logAccessGranted(long user, byte reader) {     //Log Access events
  logDate();
  Serial.print("User ");
  Serial.print(user,HEX);
  Serial.print(" granted access at reader ");
  Serial.println(reader,DEC);
}                                         

void logAccessDenied(long user, byte reader) {     //Log Access denied events
  logDate();
  Serial.print("User ");
  Serial.print(user,HEX);
  Serial.print(" denied access at reader ");
  Serial.println(reader,DEC);
}   

void logkeypadCommand(byte reader, long command){
  logDate();
  Serial.print("Command ");
  Serial.print(command,HEX);
  Serial.print(" entered at reader ");
  Serial.println(reader,DEC);
}  

void logtrainAlarm() {
  logDate();
  Serial.println("Alarm Training performed.");
}

void logalarmSensor(byte zone) {     //Log Alarm zone events
  logDate();
  Serial.print("Zone ");
  Serial.print(zone,DEC);
  Serial.println(" sensor activated");
}

void logunLock(long user, byte door) {        //Log unlock events
  logDate();
  Serial.print("User ");
  Serial.print(user,HEX);
  Serial.print(" unlocked door ");
  Serial.println(door,DEC);
  
}

void logalarmState(byte level) {        //Log unlock events
  logDate();
  Serial.print("**Alarm level changed to ");
  Serial.println(level,DEC);
}


/* Wrapper functions for interrupt attachment
*/
void callReader1Zero()
{
  wiegand26.reader1Zero();
}

void callReader1One()
{
  wiegand26.reader1One();
}

void callReader2Zero()
{
  wiegand26.reader2Zero();
}

void callReader2One()
{
  wiegand26.reader2One();
}

void callReader3Zero()
{
  wiegand26.reader3Zero();
}

void callReader3One()
{
  wiegand26.reader3One();
}


