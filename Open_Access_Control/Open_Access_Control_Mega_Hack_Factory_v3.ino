/*
 * Open Source RFID Access Controller
 *
 * 2/3/2013 v3.0.5a
 * Last build test with Arduino IDE v1.0.1
 * 
 * Arclight - arclight@23.org
 * Danozano - danozano@gmail.com
 * 
 * ######## Hack Factory updates ########
 * Hack Factory (tcmaker.org) updates include: 
 * Adding the ability to enrole keys from the door reader. 
 * 	Add a user to group 1 (user)
 * 	1) Swipe invalid Key
 *	2) Swipe staff key
 * 	3) press 666 on keypad
 * 	4) swipe new key to validate that the user is in the system, defaults to user group 5.
 *
 * Having the bell ring when the enter key is pushed from the reader pannel
 * Add date/time update from the serial port
 * Added a static user (199) who can use the side door to enter the space via 
 *	6 digit pin, in the event that they locked their key inside after hours.
 * Put the read cycle into a loop so we can decouple keypush reads from card reads. 
 *	Fixes BUG: It would require the user to swipe their card multiple times when
 * 	the reader buffer was out of sync due to a single button push or card mis-read.
 *
 * Jude Dornisch - judedornisch@gmail.com
 * David Bryan - dave@drstrangelove.net
 * 
 * ######## Hack Factory ######## 
 * Notice: This is free software and is probably buggy. Use it at
 * at your own peril.  Use of this software may result in your
 * doors being left open, your stuff going missing, or buggery by
 * high seas pirates. No warranties are expressed on implied.
 * You are warned.
 *
 *
 * For latest downloads, including Eagle CAD files for the hardware, check out
 * http://code.google.com/p/open-access-control/downloads/list
 *
 * Latest update moves strings to PROGMEM to free up memory and adds a 
 * console password feature.
 * 
 *
 * This program interfaces the Arduino to RFID, PIN pad and all
 * other input devices using the Wiegand-26 Communications
 * Protocol. It is recommended that the keypad inputs be
 * opto-isolated in case a malicious user shorts out the 
 * input device.
 * Outputs go to a Darlington relay driver array for door hardware/etc control.
 * Analog inputs are used for alarm sensor monitoring.  These should be
 * isolated as well, since many sensors use +12V. Note that resistors of
 * different values can be used on each zone to detect shorting of the sensor
 * or wiring.
 *
 * Version 1.00+ of the hardware implements these features and uses the following pin 
 * assignments on a standard Arduino Duemilanova or Uno:
 *
 * Relay outpus on digital pins 6,7,8,9
 * DS1307 Real Time Clock (I2C):A4 (SDA), A5 (SCL)
 * Analog pins (for alarm):A0,A1,A2,A3 
 * Reader 1: pins 2,3
 * Reader 2: pins 4,5
 * Ethernet: pins 10,11,12,13 (Not connected to the board, reserved for the Ethernet shield)
 *
 * Quickstart tips: 
 * Set the console password(PRIVPASSWORD) value to a numeric DEC or HEX value.
 * Define the static user list by swiping a tag and copying the value received into the #define values shown below 
 * Compile and upload the code, then log in via serial console at 57600,8,N,1
 * 
 * UPDATED 2/26/2013
 * Fixed bug with date pasrer causing program to crash and burn. 
 *
 * Usermask info:
 * 1 is a regular user with 24x7 access
 * 4 has mask 1 rights + door unlock/hold access
 * 5 has mask 1+4 + the ability to add users to the system
 * 0 and 255 are disabled and have no access
 *
 */
#define BETA_ARDUINO !(defined(ARDUINO) && ARDUINO >= 100) 

#include <Wire.h>         // Needed for I2C Connection to the DS1307 date/time chip
#include <EEPROM.h>       // Needed for saving to non-voilatile memory on the Arduino.
#include <avr/pgmspace.h> // Allows data to be stored in FLASH instead of RAM

/*
#include <Ethernet.h>   // Ethernet stuff, comment out if not used.
 #include <SPI.h>          
 #include <Server.h>
 #include <Client.h>
 */

#include <DS1307.h>       // DS1307 RTC Clock/Date/Time chip library
#include <WIEGAND26.h>    // Wiegand 26 reader format libary
// #include <PCATTACH.h>     // Pcint.h implementation, allows for >2 software interupts.


/* Static user List - Implemented as an array for testing and access override 
 */
#define DEBUG 2                         // Set to 2 for display of raw tag numbers in log files, 1 for only denied, 0 for never.               

#define david   0x1234                  // Name and badge number in HEX. We are not using checksums or site ID, just the whole
#define david2  0x1234
#define jude 0x1234
// #define snake   0x1234                  // output string from the reader.
//#define satan   0x1234
const unsigned long  superUserList[] = { david, david2, jude};  // Super user table (cannot be changed by software)

#define PRIVPASSWORD 0x1234             // Console "priveleged mode" password

#define DOORDELAY 3000                  // How long to open door lock once access is granted. (2500 = 2.5s)
#define SENSORTHRESHOLD 100             // Analog sensor change that will trigger an alarm (0..255)

#define EEPROM_ALARM 0                  // EEPROM address to store alarm triggered state between reboots (0..511)
#define EEPROM_ALARMARMED 1             // EEPROM address to store alarm armed state between reboots
#define EEPROM_ALARMZONES 20            // Starting address to store "normal" analog values for alarm zone sensor reads.
#define KEYPADTIMEOUT 5000              // Timeout for pin pad entry. Users on keypads can enter commands after reader swipe.

#define EEPROM_FIRSTUSER 48
#define EEPROM_LASTUSER 2048
#define NUMUSERS  ((EEPROM_LASTUSER - EEPROM_FIRSTUSER)/5)  //Define number of internal users (200 for UNO/Duemillanova)

#define DOORPIN1 relayPins[1]           // Define the pin for electrified door 1 hardware
#define DOORPIN2 relayPins[0]           // Define the pin for electrified door 2 hardware
#define GRNLED1 5                       // Define the pin for green LED on reader 1
#define GRNLED2 7                       // Define the pin for green LED on reader 2
#define ALARMSTROBEPIN relayPins[2]     // Define the "non alarm: output pin. Can go to a strobe, small chime, etc
#define ALARMSIRENPIN  relayPins[3]     // Define the alarm siren pin. This should be a LOUD siren for alarm purposes.

uint8_t reader1Pins[]={2,3};               // Reader 1 connected to pins 2,3
uint8_t reader2Pins[]= {19,18};            // Reader2 connected to pins 19,18

const uint8_t analogsensorPins[] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14};    // Alarm Sensors connected to other analog pins
const uint8_t relayPins[]= {31,32,33,34,35,36,37,38};                       // Relay output pins

bool door1Locked=true;                        // Keeps track of whether the doors are supposed to be locked right now
bool door2Locked=true;

unsigned long door1locktimer=0;               // Keep track of when door is supposed to be relocked
unsigned long door2locktimer=0;               // after access granted.

boolean doorChime=false;                       // Keep track of when door chime last activated
boolean doorClosed=false;                      // Keep track of when door last closed for exit delay

unsigned long alarmDelay=0;                    // Keep track of alarm delay. Used for "delayed activation" or level 2 alarm.
unsigned long alarmSirenTimer=0;               // Keep track of how long alarm has gone off

unsigned long consolefailTimer=0;               // Console password timer for failed logins
uint8_t consoleFail=0;
#define numUsers (sizeof(superUserList)/sizeof(long))                  //User access array size (used in later loops/etc)
#define NUMDOORS (sizeof(doorPin)/sizeof(byte))
#define numAlarmPins (sizeof(analogsensorPins)/sizeof(byte))

//Other global variables
uint8_t second, minute, hour, dayOfWeek, dayOfMonth, month, year;     // Global RTC clock variables. Can be set using DS1307.getDate function.

uint8_t alarmActivated = EEPROM.read(EEPROM_ALARM);                   // Read the last alarm state as saved in eeprom.
uint8_t alarmArmed = EEPROM.read(EEPROM_ALARMARMED);                  // Alarm level variable (0..5, 0==OFF) 

boolean sensor[4]={false};                                         // Keep track of tripped sensors, do not log again until reset.
unsigned long sensorDelay[2]={0};                                  // Same as above, but sets a timer for 2 of them. Useful for logging
                                                                   // motion detector hits for "occupancy check" functions.

// Enable up to 2 door access readers.
volatile long reader1 = 0;
volatile int  reader1Count = 0;
volatile long reader2 = 0;
volatile int  reader2Count = 0;

unsigned long keypad1Value=0;
unsigned long keypad1Time=0;                  //  Timeout counter for  reader with key pad
unsigned long keypad2Value=0;
unsigned long keypad2Time=0;                  //  Timeout counter for  reader with key pad

unsigned long invalidkey = 0;                                  //added store last invalid key at reader 1 for possible later add

int userMask1=0;
int userMask2=0;

boolean keypadGranted=false;                                   // Variable that is set for authenticated users to use keypad after login

// Serial terminal buffer (needs to be global)
char inString[70]={0};                                         // Size of command buffer (<=128 for Arduino)
uint8_t inCount=0;
boolean privmodeEnabled = false;                               // Switch for enabling "priveleged" commands


/* Create an instance of the various C++ libraries we are using.
 */

DS1307 ds1307;        // RTC Instance
WIEGAND26 wiegand26;  // Wiegand26 (RFID reader serial protocol) library

/* Set up some strings that will live in flash instead of memory. This saves our precious 2k of
 * RAM for something else.
 */

const prog_uchar rebootMessage[]          PROGMEM  = {"Access Control System rebooted."};
const prog_uchar doorChimeMessage[]       PROGMEM  = {"Front Door opened."};
const prog_uchar doorslockedMessage[]     PROGMEM  = {"All Doors relocked"};
const prog_uchar alarmtrainMessage[]      PROGMEM  = {"Alarm Training performed."};
const prog_uchar privsdeniedMessage[]     PROGMEM  = {"Access Denied. Priveleged mode is not enabled."};
const prog_uchar privsenabledMessage[]    PROGMEM  = {"Priveleged mode enabled."};
const prog_uchar privsdisabledMessage[]   PROGMEM  = {"Priveleged mode disabled."};
const prog_uchar privsAttemptsMessage[]   PROGMEM  = {"Too many failed attempts. Try again later."};


const prog_uchar consolehelpMessage1[]    PROGMEM  = {"Valid commands are:"};
const prog_uchar consolehelpMessage2[]    PROGMEM  = {"(d)ate, (s)show user, (m)odify user <num>  <usermask> <tagnumber>"};
const prog_uchar consolehelpMessage3[]    PROGMEM  = {"Add a key: (n) <tagnumber>"};
const prog_uchar consolehelpMessage4[]    PROGMEM  = {"(a)ll user dump,(r)emove_user <num>,(o)open door <num>"};
const prog_uchar consolehelpMessage5[]    PROGMEM  = {"(u)nlock all doors,(l)lock all doors"};
const prog_uchar consolehelpMessage6[]    PROGMEM  = {"(1)disarm_alarm, (2)arm_alarm,(3)train_alarm (9)show_status"};
const prog_uchar consolehelpMessage7[]    PROGMEM  = {"(t)ime set <sec 0..59> <min 0..59> <hour 0..23> <day of week 1..7>"};
const prog_uchar consolehelpMessage8[]    PROGMEM  = {"           <day 0..31> <mon 0..12> <year 0.99>"};
const prog_uchar consolehelpMessage9[]    PROGMEM  = {"(e)nable <password> - enable or disable priveleged mode"};                                       
const prog_uchar consolehelpMessage10[]    PROGMEM  = {"(h)ardware test - Test the hardware"}; 
const prog_uchar consolehelpMessage11[]    PROGMEM  = {"Usermask 0: Unprovisioned 1: Normal, 4: Unlock+hold door, "}; 
const prog_uchar consolehelpMessage12[]    PROGMEM  = {"         5: N+UH+Adduser access 255: account disabled"};
const prog_uchar consoledefaultMessage[]  PROGMEM  = {"Invalid command. Press '?' for help."}; 

const prog_uchar statusMessage1[]         PROGMEM  = {"Alarm armed state (1=armed):"};
const prog_uchar statusMessage2[]         PROGMEM  = {"Alarm siren state (1=activated):"};
const prog_uchar statusMessage3[]         PROGMEM  = {"Front door open state (0=closed):"};
const prog_uchar statusMessage4[]         PROGMEM  = {"Roll up door open state (0=closed):"};     
const prog_uchar statusMessage5[]         PROGMEM  = {"Door 1 unlocked state(1=locked):"};                   
const prog_uchar statusMessage6[]         PROGMEM  = {"Door 2 unlocked state(1=locked):"}; 
const prog_uchar statusMessage7[]         PROGMEM  = {"Battery Voltage:"}; 

void setup(){           // Runs once at Arduino boot-up

    Wire.begin();   // start Wire library as I2C-Bus Master

  /* Attach pin change interrupt service routines from the Wiegand RFID readers
   */
  // ds1307.setDateDs1307(0,29,16,7,19,5,12); 
  attachInterrupt(0,callReader1Zero, CHANGE);  //Attach the hardware interrupts to the Wiegand data pins
  attachInterrupt(1,callReader1One, CHANGE);
  attachInterrupt(4,callReader2Zero, CHANGE);
  attachInterrupt(5,callReader2One, CHANGE);


  //Clear and initialize readers
  wiegand26.initReaderOne();                    //Set up Reader 1,2 and clear buffers.
  wiegand26.initReaderTwo(); 

  //Initialize output relays
  for(uint8_t i=0; i<4; i++){        
    pinMode(relayPins[i], OUTPUT);                                                      
    digitalWrite(relayPins[i], LOW);                  // Sets the relay outputs to LOW (relays off)
  }

  // Initialize door LED pins
  // LOW == activated

  pinMode(4,OUTPUT);  // Reader 0 red LED
  pinMode(5,OUTPUT);  // Reader 0 green LED
  pinMode(6,OUTPUT);  // Reader 0 buzzer

  digitalWrite(4,HIGH);
  digitalWrite(5,HIGH);
  digitalWrite(6,HIGH);

  pinMode(7,OUTPUT);  // Reader 1 red LED
  pinMode(8,OUTPUT);  // Reader 1 green LED
  pinMode(17,OUTPUT); // Reader 1 buzzer

  digitalWrite(7,HIGH);
  digitalWrite(8,HIGH);
  digitalWrite(17,HIGH);

/*
  // Change these values to what you want to set your clock to.
  // You probably only want to set your clock once and then remove
  // the setDateDs1307 call.
  uint8_t   second = 0;
  uint8_t   minute = 30;
  uint8_t   hour = 2;
  uint8_t   dayOfWeek = 3;
  uint8_t   dayOfMonth = 26;
  uint8_t   month = 2;
  uint8_t   year = 13;
  ds1307.setDateDs1307(second, minute, hour, dayOfWeek, dayOfMonth, month, year);
*/

  pinMode(16, OUTPUT);                          // Set up the RS-485 TX enable pin on pin 16.
  digitalWrite(16, LOW);

  Serial.begin(57600);	               	       // Set up the USB Serial output at 8,N,1,57600bps
  Serial2.begin(57600);                        // Set up the RS485 serial port on pins 14,15. TX enable on pin 16

  logReboot();
  chirpAlarm(1);                               // Chirp the alarm to show system ready.

  // hardwareTest(200);                         // IO Pin testing routing (use to check your inputs with hi/lo +(5-12V) sources)
  // Also checks relays
}
void loop()                                     // Main branch, runs over and over again
{                         

  readCommand();                                 // Check for commands entered at serial console

  /* Check if doors are supposed to be locked and lock/unlock them 
   * if needed. Uses global variables that can be set in other functions.
   */

  if(((millis() - door1locktimer) >= DOORDELAY) && (door1locktimer !=0))
  { 
    if(door1Locked==true){
      doorLock(1);
      door1locktimer=0;    
    }

    else {                        
      doorUnlock(1); 
      door1locktimer=0;
    }                         
  }

  if(((millis() - door2locktimer) >= DOORDELAY) && (door2locktimer !=0))
  { 
    if(door2Locked==true) {
      doorLock(2); 
      door2locktimer=0;
    }

    else {
      doorUnlock(2); 
      door2locktimer=0;
    }   
  }   

  /*  Set optional "failsafe" time to lock up every night.
   */

  ds1307.getDateDs1307(&second, &minute, &hour, &dayOfWeek, &dayOfMonth, &month, &year);   // Get the current date/time

  if(hour==23 && minute==59 && door1Locked==false){
    doorLock(1);
    door1Locked==true;      
    doorLock(2);
    door2Locked==true;      
    Serial.println("Door 1&2 locked for 2359 bed time.");
  }

  // Notes: RFID polling is interrupt driven, just test for the reader1Count value to climb to the bit length of the key
  // change reader1Count & reader1 et. al. to arrays for loop handling of multiple reader output events
  // later change them for interrupt handling as well!
  // currently hardcoded for a single reader unit

  /* This code checks a reader with a 26-bit keycard input. Use the second routine for readers with keypads.  
   * A 5-second window for commands is opened after each successful key access read.
   */

  /* Tcmaker / Hack Factory
   I've rewritten the main reader code to allow for keypad entry without an RFID read
   The previous code triggered when the read reached 26 bits keypad or rfid tag
   Thus if a keypad entry was hanging you had to fill the buffer to clear it before a read would work
   A side benefit of separating keypad and rfid tag reading is to keep the buffer clear
   
   The basic logic is that the interupts are faster then the processing loop and any human input at the pad
   So we track the change in reader bit count and the loops it takes between to determine if we are still in a read event
   */

  //  loopcnt++; 
  if (reader1Count == 4){    // this should be a key input
    keypad1Time = millis();
    switch(reader1) {
    case 0xA: 
      {
        keypad1Value = 0;
        break;
      }
    case 0xB: 
      {
        runCommand1(keypad1Value,1,userMask1);
        keypad1Time = 0;
        keypad1Value = 0;
        break;
      }
    default: 
      {
        keypad1Value = keypad1Value <<4;
        keypad1Value = keypad1Value + reader1;               
      }     
    }  
    reader1 = 0;
    reader1Count = 0;    
  }

  if(reader1Count >= 26){                           //  When tag presented to reader1 - Keypad is present
    logTagPresent(reader1,1);                       //  write log entry to serial port
    //    keypadGranted=false;

    /* Check a user's security level and take action as needed. The
     *  usermask is a variable from 0..255. By default, 0 and 255 are for
     *  locked out users or uninitialized records.
     *  Modify these for each door as needed.
     */


    userMask1=getUserMask(reader1);
    if(userMask1>=0) {
      keypad1Time = millis();                  //  Timeout counter for  reader with key pad

      switch(userMask1) {

      case 0:                                      // No outside privs, do not log denied.
        {                                           // authenticate only.
          logAccessGranted(reader1, 1);
          break;
        }

      case 4:                                       //added allow keypad access for selected
        {
          logAccessGranted(reader1, 1);           // Log and unlock door 1
          alarmState(0);
          armAlarm(0);                            //  Deactivate Alarm                  
          door1locktimer=millis();
          doorUnlock(1);                          // Unlock the door.
          //         keypadGranted=1;
          break;
        }

      case 5:                                       //added allow keypad access for selected
        {
          logAccessGranted(reader1, 1);           // Log and unlock door 1
          alarmState(0);
          armAlarm(0);                            //  Deactivate Alarm                  
          door1locktimer=millis();
          doorUnlock(1);                          // Unlock the door.
          //         keypadGranted=1;
          break;
        }
      case 20:                                                // Example Limited hours user
        {                                                      // Can enter from 5:00pm to 11:00pm
          /*    ds1307.getDateDs1307(&second, &minute, &hour, &dayOfWeek, &dayOfMonth, &month, &year);    */
          if((hour >=17) && (hour <=23)){
            logAccessGranted(reader1, 1);                    // Log and unlock door 2
            alarmState(0);
            armAlarm(0);                                     //  Deactivate Alarm
            //   chirpAlarm(1);                            
            door1locktimer=millis();
            doorUnlock(1);                                   // Unlock the door.

          }
          break;
        }      

      case 255:                                              // Locked out user     
        {
          Serial.print("User ");
          Serial.print(userMask1,DEC);
          Serial.println(" locked out.");
          break;
        }

      default:  
        {            
          logAccessGranted(reader1, 1);           // Log and unlock door 1
          alarmState(0);
          armAlarm(0);                            //  Deactivate Alarm                  
          door1locktimer=millis();
          doorUnlock(1);                          // Unlock the door.
          break;
        }
      }                                      

    }
    else 
    {                                           
      logAccessDenied(reader1,1);                   // No tickee, no laundree
      invalidkey=reader1;
    }
    wiegand26.initReaderOne();                     // Reset for next tag scan

  }
  if ((millis() - keypad1Time)  > KEYPADTIMEOUT){
    userMask1 = 255;
    //   invalidkey = 0;
    keypad1Value = 0;
  }


  if (reader2Count == 4){    // this should be a key input
    keypad2Time = millis();
    switch(reader2) {
    case 0xA: 
      {
        keypad2Value = 0;
        break;
      }
    case 0xB: 
      {
        runCommand1(keypad2Value,2,userMask2);
        keypad2Time = 0;
        keypad2Value = 0;
        break;
      }
    default: 
      {
        keypad2Value = keypad2Value <<4;
        keypad2Value = keypad2Value + reader2;               
      }     
    }  
    reader2 = 0;
    reader2Count = 0;    
  }


  if(reader2Count >= 26)
  {                                // Tag presented to reader 2
    logTagPresent(reader2,2);                            // Write log entry to serial port
    chirpAlarm(1);                                       // Chirp alarm to show that tag input done              
    // CHECK TAG IN OUR LIST OF USERS. -1 = no match                                  
    //  keypadGranted=false;                                  
    userMask2=getUserMask(reader2);    

    if(userMask2>=0){    
      switch(userMask2) {

      case 0:                         // No outside privs, do not log denied.
        {                              // authenticate and log only.
          logAccessGranted(reader2, 2);
          break;
        }
      
      case 4:                                       //added allow keypad access for selected
        {
          logAccessGranted(reader2, 2);           // Log and unlock door 2
          alarmState(0);
          armAlarm(0);                            //  Deactivate Alarm                  
          door2locktimer=millis();
          doorUnlock(2);                          // Unlock the door.
          //         keypadGranted=1;
        }

      
      case 5:                                       //added allow keypad access for selected
        {
          logAccessGranted(reader2, 2);           // Log and unlock door 2
          alarmState(0);
          armAlarm(0);                            //  Deactivate Alarm                  
          door2locktimer=millis();
          doorUnlock(2);                          // Unlock the door.
          //         keypadGranted=1;
        }

      case 10:                         // Authenticating immediately locks up and arms alarm
        {                              // 
          logAccessGranted(reader2, 2);
          runCommand1(0x2,0,0);
          break;
        }

      case 20:                                               //Limited hours user
        {
          //    ds1307.getDateDs1307(&second, &minute, &hour, &dayOfWeek, &dayOfMonth, &month, &year);    
          if((hour >=17) && (hour <=23)){
            logAccessGranted(reader2, 2);                    // Log and unlock door 2
            alarmState(0);
            armAlarm(0);                                     //  Deactivate Alarm                           
            door2locktimer=millis();
            doorUnlock(2);                                   // Unlock the door.
            // keypadGranted=1;
          }
          break;
        }

      case 255:                                               // Locked out      
        {
          Serial.print("User ");
          Serial.print(userMask2,DEC);
          Serial.println(" locked out.");
          break;
        }

      default:  
        {            
          logAccessGranted(reader2, 2);           // Log and unlock door 2
          alarmState(0);
          armAlarm(0);                            //  Deactivate Alarm                          
          door2locktimer=millis();
          doorUnlock(2);                          // Unlock the door.
          break;
        }
      }                                      

    }
    else 
    {                                             
      /*     if(checkSuperuser(reader2) >= 0) {              // Check if a superuser, grant access.
       logAccessGranted(reader2, 2);                 // Log and unlock door 2
       alarmState(0);
       armAlarm(0);                              //  Deactivate Alarm
       chirpAlarm(1);                            
       door2locktimer=millis();
       doorUnlock(2);                            // Unlock the door.
       keypadGranted=1;
       }
       else{  */
      logAccessDenied(reader2,2);                 //  no tickee, no laundree
      //          }
    }

    wiegand26.initReaderTwo();                   //  Reset for next tag scan
    /*    unsigned long keypadTime=0;                  //  Timeout counter for  reader with key pad
     long keypadValue=0;
     keypadTime=millis();  
     
     if(keypadGranted==1) 
     {
     while((millis() - keypadTime)  <=KEYPADTIMEOUT){
     
     // If access granted, open 5 second window for pin pad commands.
     if(reader2Count >=4){
     if(reader2 !=0xB){                                  // Pin pad command can be any length, terminated with '#' on the keypad.
     if(keypadValue ==0){                              // This 0..9, A..F encoding works with many Wiegand-format keypad or reader 
     keypadValue = reader2;                          // plus keypad units.
     
     }
     else if(keypadValue !=0) {
     keypadValue = keypadValue <<4;
     keypadValue |= reader2;               
     }
     wiegand26.initReaderTwo();                         //Reset reader one and move on.
     } 
     else break;
     
     }
     
     }
     
     logkeypadCommand(2,keypadValue);
     runCommand(keypadValue,2,userMask2);                              // Run any commands entered at the keypads.
     wiegand26.initReaderTwo();
     
     
     }*/
    if ((millis() - keypad2Time)  > KEYPADTIMEOUT){
      userMask2 = 255;
      //      invalidkey = 0;
      keypad2Value = 0;
      keypadGranted = false;
    }
    wiegand26.initReaderTwo();                    
  } 

  /* Check physical sensors with 
   the logic below. Behavior is based on
   the current alarmArmed value.
   0=disarmed 
   1=armed
   2=
   3=
   4=door chime only (Unlock DOOR1, Check zone 0/chirp alarm if active)
   
   Modify the alarm sequence to meet your needs.
   */

  switch(alarmArmed) {


  case 0:
    {
      break;                                        // Alarm is not armed, do nothing.  
    }

  case 1:                                       // Alarm is armed
    {


      if(alarmActivated==0){                       // If alarm is armed but not currently alarming, check sensor zones.

        if(pollAlarm(0) == 1 ){                   // If this zone is tripped, immediately set Alarm State to 2 (alarm delay).
          alarmState(2);                        // Also starts the delay timer    
          alarmDelay=millis();
          if(sensor[0]==false) {                // Only log and save if sensor activation is new.
            logalarmSensor(0);
            EEPROM.write(EEPROM_ALARM,0);        // Save the alarm sensor tripped to eeprom                                      
            sensor[0]=true;                      // Set value to not log this again                                                                        
          }
        } 
        if(pollAlarm(1) == 1 ){                  // If this zone is tripped, immediately set Alarm State to 1 (alarm immediate).
          alarmState(1);      
          if(sensor[1]==false) {                // Only log and save if sensor activation is new.
            logalarmSensor(1);
            EEPROM.write(EEPROM_ALARM,1);        // Save the alarm sensor tripped to eeprom                                     
            sensor[1]=true;                      // Set value to not log this again
          }  
        }
        if(pollAlarm(2) == 1 ){                  // If this zone is tripped, immediately set Alarm State to 1 (alarm immediate).
          alarmState(1);      
          if(sensor[2]==false) {                // Only log and save if sensor activation is new.
            logalarmSensor(2);
            EEPROM.write(EEPROM_ALARM,2);        // Save the alarm sensor tripped to eeprom                                     
            sensor[2]=true;                      // Set value to not log this again
          }    

        } 

        if(pollAlarm(3) == 1 ){                   // If this zone is tripped, immediately set Alarm State to 2 (alarm delay).
          alarmState(2);                        // Also starts the delay timer    
          alarmDelay=millis();
          if(sensor[3]==false) {                // Only log and save if sensor activation is new.
            logalarmSensor(3);
            EEPROM.write(EEPROM_ALARM,3);        // Save the alarm sensor tripped to eeprom                                      
            sensor[3]=true;                      // Set value to not log this again                                                                        
          }
        }    



      }
      if(alarmActivated==1)  {                         // If alarm is actively going off (siren/strobe) for 10 min (6e5=10min)
        if(millis()-alarmSirenTimer >=3.6e6)            // Check for alarm interval expired and turn off if needed
        {
          digitalWrite(ALARMSIRENPIN,LOW);              // Turn on the chime instead  
          digitalWrite(ALARMSTROBEPIN,HIGH);     
        }
      }  

      if(alarmActivated==2)  {                         // If alarm is activated on delay, take this action
        if(millis()-alarmDelay >=60000)                 // Turn on the siren once delay exceeds 60sec.
        {
          alarmState(1);                          
        }
      }  

      break;

    }

  case 4: 
    {                                                // Door chime mode

      if((pollAlarm(3) !=0) && (doorChime==false)) {   // Only activate door chime once per opening
        chirpAlarm(3);                  
        logChime();
        doorChime=true;   
      }
      if(pollAlarm(3) ==0){
        doorChime=false;   
      }
      break;    

    }

  default: 
    {
      break;  
    }
  }

  // Log all motion detector activations regardless of alarm armed state. Useful for "occupancy detection"

  if(pollAlarm(0) == 1 ){                  // If this zone is tripped, log the action only
    //  if(sensor[0]==false) 
    if((millis() - sensorDelay[0]) >=7500) {
      logalarmSensor(0);   
      sensorDelay[0]=millis();                                                                  
      sensor[0]=true;      
    }                 // Set value to not log this again for 7.5s              
  }

  if(pollAlarm(1) == 1 ){                  // If this zone is tripped, log the action only
    //   if(sensor[1]==false) 
    if((millis() - sensorDelay[1]) >=7500) {
      logalarmSensor(1);   
      sensorDelay[1]=millis();                                                            
      sensor[1]=true;                       // Set value to not log this again for 7.5s
    }           
  }
} // End of loop()

void runCommand1(long command, uint8_t reader, int userMask) {         // Run any commands entered at the pin pad.
  Serial.print("test command ");
  Serial.print(command,DEC);
  Serial.print(" Door ");
  Serial.print(reader,DEC);
  Serial.print(" mask ");
  Serial.println(userMask,DEC);
  if (command == 0) {
    ringBell(reader);
    // Serial.print("Ring Bell ");
  }
  if (command == 0x911) {
    Serial.print("911   ");
  }
  if (command == 5){
    Serial.print("5 Lock all   ");
    lockall();
    chirpAlarm(5);
  }

  if ((command == 0x666) && (reader == 2)){
    Serial.print("666  emergency enter ");
    keypadGranted = true;
    chirpAlarm(5);
  }   

  if (keypadGranted && (reader == 2)) {
    if (getUserMask(command) == 1) {
      logAccessGranted(reader2, 2);                    // Log and unlock door 2
      alarmState(0);
      armAlarm(0);                                     //  Deactivate Alarm                           
      door2locktimer=millis();
      doorUnlock(2);                                   // Unlock the door.

    }
  }

  if ((userMask > 0) && (userMask < 255)){
    if (command == 1) {
      Serial.print("1 deactivate   ");
      alarmState(0);                      // Set global alarm level variable
      armAlarm(0);
      chirpAlarm(1);
    }
    if (command == 2) {
      Serial.print("2 activate   ");
      doorUnlock(1);                        // Set global alarm level variable
      door1Locked=false;
      doorClosed=false;                      // 200 chirps = ~30 seconds delay

      if((pollAlarm(3) == 0) && (pollAlarm(2) == 0)) {                  // Do not arm the alarm if doors are open

        for(uint8_t i=0; i<30; i++) {
          if((pollAlarm(3) !=0) && doorClosed==false) {             // Set door to be unlocked until alarm timeout or user exits
            lockall();    
            doorClosed=true; 
          }      
          digitalWrite(ALARMSTROBEPIN, HIGH);
          delay(500);
          digitalWrite(ALARMSTROBEPIN, LOW);
          delay(500);                        
        }
        chirpAlarm(2);
        armAlarm(1);                 
        lockall();                                                  // Lock all doors on exit
      }
      else {                                                          // Beep the alarm once and exit if attempt made to arm alarm with doors ope

        digitalWrite(ALARMSTROBEPIN, HIGH);
        delay(500);
        digitalWrite(ALARMSTROBEPIN, LOW);
        delay(500);                        
        lockall();                                                  // Lock all doors anyway
      } 
    }
    if (userMask > 1){
      if (command == 3){
        if (reader == 1)
        {
          doorUnlock(1);
          door1Locked=false;
        }
        else
        {
          doorUnlock(2);
          door2Locked=false;
        }  
        chirpAlarm(3);   
      }
      if (userMask >= 4){
        if (command == 4){
          doorUnlock(1);
          door1Locked=false;
          doorUnlock(2);
          door2Locked=false; 
        }
        if ((command == 0x666) && (userMask == 5))
        { 
          Serial.print("666 entered...  ");
          Serial.println(invalidkey,HEX);
          if((reader == 1) && (invalidkey != 0)) { 
            addnewkey(invalidkey);
          }
        }  
      }
    }   
  }
}

/* Alarm System Functions - Modify these as needed for your application. 
 Sensor zones may be polled with digital or analog pins. Unique reader2
 resistors can be used to check more zones from the analog pins.
 */


void alarmState(uint8_t alarmLevel) {                    //Changes the alarm status based on this flow

  logalarmState(alarmLevel); 
  switch (alarmLevel) {                              
  case 0: 
    {                                                 // If alarmLevel == 0 turn off alarm.   
      digitalWrite(ALARMSIRENPIN, LOW);
      digitalWrite(ALARMSTROBEPIN, LOW);
      alarmActivated = alarmLevel;                    //Set global alarm level variable
      break;  
    }        
  case 1: 
    { 
      digitalWrite(ALARMSIRENPIN, HIGH);               // If alarmLevel == 1 turn on strobe lights and siren
      //    digitalWrite(ALARMSTROBEPIN, HIGH);            // Optionally activate yoru strobe/chome
      alarmSirenTimer=millis();
      alarmActivated = alarmLevel;                    //Set global alarm level variable
      logalarmTriggered();

      break;  
    }        

  case 2:                                        
    {
      digitalWrite(ALARMSTROBEPIN, HIGH);   
      alarmActivated = alarmLevel;
      break;    
    }

  case 3:                                        
    {

      alarmActivated = alarmLevel;
      break;    
    }
    /*
      case 4: {
     vaporize_intruders(STUN);
     break;
     }
     
     case 5: {
     vaporize_intruders(MAIM);
     }  etc. etc. etc.
     break;
     */

  default: 
    {                                            // Exceptional cases kill alarm outputs
      digitalWrite(ALARMSIRENPIN, LOW);          // Turn off siren and strobe
      // digitalWrite(ALARMSTROBEPIN, LOW);        
      break;
    } 




  }

  if(alarmActivated != EEPROM.read(EEPROM_ALARM)){    // Update eeprom value
    EEPROM.write(EEPROM_ALARM,alarmActivated); 
  }

}  //End of alarmState()


void chirpAlarm(uint8_t chirps){            // Chirp the siren pin or strobe to indicate events.      
  /*  for(uint8_t i=0; i<chirps; i++) {
   digitalWrite(ALARMSTROBEPIN, HIGH);
   delay(100);
   digitalWrite(ALARMSTROBEPIN, LOW);
   delay(200);                              
   }    */
}   


void ringBell(uint8_t Door){            // Chirp the siren pin or strobe to indicate events.      
  if (Door == 2) { 
    logDate();
    Serial.print("Side doorbell has been pushed.");
    Serial.println();
    digitalWrite(ALARMSTROBEPIN, HIGH);
    delay(200);
    digitalWrite(ALARMSTROBEPIN, LOW);
    delay(50);
    digitalWrite(ALARMSTROBEPIN, HIGH);
    delay(200);
    digitalWrite(ALARMSTROBEPIN, LOW);
    delay(50);
    digitalWrite(ALARMSTROBEPIN, HIGH);
    delay(200);
    digitalWrite(ALARMSTROBEPIN, LOW);
  }
  else if (Door == 1){
    logDate();
    Serial.print("Front doorbell has been pushed.");
    Serial.println();
    digitalWrite(ALARMSTROBEPIN, HIGH);
    delay(250);
    digitalWrite(ALARMSTROBEPIN, LOW);
    delay(50);
    digitalWrite(ALARMSTROBEPIN, HIGH);
    delay(250);
    digitalWrite(ALARMSTROBEPIN, LOW);
    delay(50);
  }

}                                   

uint8_t pollAlarm(uint8_t input){

  // Return 1 if sensor shows < pre-defined voltage.
  delay(20);
  if(abs((analogRead(analogsensorPins[input])/4) - EEPROM.read(EEPROM_ALARMZONES+input)) >SENSORTHRESHOLD){
    return 1;

  }
  else return 0;
}


void trainAlarm(){                       // Train the system about the default states of the alarm pins.
  armAlarm(0);                           // Disarm alarm first
  alarmState(0);

  int temp[5]={
    0  };
  int avg;

  for(int i=0; i<numAlarmPins; i++) {         

    for(int j=0; j<5;j++){                          
      temp[j]=analogRead(analogsensorPins[i]);
      delay(50);                                         // Give the readings time to settle
    }
    avg=((temp[0]+temp[1]+temp[2]+temp[3]+temp[4])/20);  // Average the results to get best values
    Serial.print("Sensor ");
    Serial.print(i);
    Serial.print(" ");
    Serial.print("value:");
    Serial.println(avg);
    EEPROM.write((EEPROM_ALARMZONES+i),uint8_t(avg));   //Save results to EEPROM
    avg=0;
  }

  logDate();
  PROGMEMprintln(alarmtrainMessage);


}


void armAlarm(uint8_t level){                       // Arm the alarm and set to level
  alarmArmed = level;
  logalarmArmed(level);

  sensor[0] = false;                             // Reset the sensor tripped values
  sensor[1] = false;
  sensor[2] = false;
  sensor[3] = false;

  if(level != EEPROM.read(EEPROM_ALARMARMED)){ 
    EEPROM.write(EEPROM_ALARMARMED,level); 
  }
}

/* Access System Functions - Modify these as needed for your application. 
 These function control lock/unlock and user lookup.
 */

int checkSuperuser(unsigned long input){       // Check to see if user is in the user list. If yes, return their index value.
  int found=-1;
  for(int i=0; i<=numUsers; i++){   
    if(input == superUserList[i]){
      logDate();
      Serial.print("Superuser ");
      Serial.print(i,DEC);
      Serial.println(" found.");
      found=i;
      return found;    
    }
  }                   
  return found;             //If no, return -1
}


void doorUnlock(int input) {          //Send an unlock signal to the door and flash the Door LED
  uint8_t dp=1;
  uint8_t gp=1;
  if(input == 1) {
    gp=GRNLED1;
    dp=DOORPIN1; 
  }
  else {
    gp=GRNLED2; 
    dp=DOORPIN2;
  }
  digitalWrite(dp, HIGH);
  digitalWrite(gp, LOW);                  // Set the green LED status on the reader
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" unlocked");

}


void doorLock(int input) {          //Send an unlock signal to the door and flash the Door LED
  uint8_t dp=1;
  uint8_t gp=1;
  if(input == 1) {
    gp=GRNLED1;
    dp=DOORPIN1; 
  }
  else
  {
    gp=GRNLED2;
    dp=DOORPIN2;
  }

  digitalWrite(dp, LOW);         // Set the green LED status on the reader
  digitalWrite(gp, HIGH);
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" locked");

}
void lockall() {                      //Lock down all doors. Can also be run periodically to safeguard system.

  digitalWrite(DOORPIN1, LOW);
  digitalWrite(DOORPIN2,LOW);
  door1Locked=true;
  door2Locked=true;
  PROGMEMprintln(doorslockedMessage);

}

/* Logging Functions - Modify these as needed for your application. 
 Logging may be serial to USB or via Ethernet (to be added later)
 */


void PROGMEMprintln(const prog_uchar str[])    // Function to retrieve logging strings from program memory
{                                              // Prints newline after each string  
  char c;
  if(!str) return;
  while((c = pgm_read_byte(str++))){
    Serial.write(c);
  }
  Serial.println();
}

void PROGMEMprint(const prog_uchar str[])    // Function to retrieve logging strings from program memory
{                                            // Does not print newlines
  char c;
  if(!str) return;
  while((c = pgm_read_byte(str++))){
    Serial.write(c);
  }

}

void logDate()
{
  ds1307.getDateDs1307(&second, &minute, &hour, &dayOfWeek, &dayOfMonth, &month, &year);
  if(hour <= 9) {
    Serial.print("0");
  }
  Serial.print(hour, DEC);
  Serial.print(":");
  if(minute <= 9) {
    Serial.print("0");
  }
  Serial.print(minute, DEC);
  Serial.print(":");
  if(second <= 9) {
    Serial.print("0");
  }
  Serial.print(second, DEC);
  Serial.print("  ");
  if(month <= 9) {
    Serial.print("0");
  }
  Serial.print(month, DEC);
  Serial.print("/");
  if(dayOfMonth <= 9) {
    Serial.print("0");
  }
  Serial.print(dayOfMonth, DEC);
  Serial.print("/");
  Serial.print(year, DEC);
  Serial.print(' ');

  switch(dayOfWeek){

  case 1:
    {
      Serial.print("SUN");
      break;
    }
  case 2:
    {
      Serial.print("MON");
      break;
    }
  case 3:
    {
      Serial.print("TUE");
      break;
    }
  case 4:
    {
      Serial.print("WED");
      break;
    }
  case 5:
    {
      Serial.print("THU");
      break;
    }
  case 6:
    {
      Serial.print("FRI");
      break;
    }
  case 7:
    {
      Serial.print("SAT");
      break;
    }  
  }

  Serial.print(" ");

}


void logReboot() {                                  //Log system startup
  logDate();
  PROGMEMprintln(rebootMessage);
}

void logChime() {
  logDate();
  PROGMEMprintln(doorChimeMessage);
}

void logTagPresent (long user, uint8_t reader) {     //Log Tag Presented events
  logDate();
  Serial.print("User ");
  if(DEBUG>=2){ 
    Serial.print(user,HEX);
  }
  Serial.print(" presented tag at reader ");
  Serial.println(reader,DEC);
}

void logAccessGranted(long user, uint8_t reader) {     //Log Access events
  logDate();
  Serial.print("User ");
  if(DEBUG>=2){
    Serial.print(user,HEX);
  }
  Serial.print(" granted access at reader ");
  Serial.println(reader,DEC);
}                                         

void logAccessDenied(long user, uint8_t reader) {     //Log Access denied events
  logDate();
  Serial.print("User ");
  if(DEBUG>=1){
    Serial.print(user,HEX);
  } 
  Serial.print(" denied access at reader ");
  Serial.println(reader,DEC);
}   

void logkeypadCommand(uint8_t reader, long command){
  logDate();
  Serial.print("Command ");
  Serial.print(command,HEX);
  Serial.print(" entered at reader ");
  Serial.println(reader,DEC);
}   


void logalarmSensor(uint8_t zone) {     //Log Alarm zone events
  logDate();
  Serial.print("Zone ");
  Serial.print(zone,DEC);
  Serial.println(" sensor activated");
}

void logalarmTriggered() {
  logDate();
  Serial.println("Alarm triggered!");   // This phrase can be scanned for by alerting scripts.
}

void logunLock(long user, uint8_t door) {        //Log unlock events
  logDate();
  Serial.print("User ");
  Serial.print(user,DEC);
  Serial.print(" unlocked door ");
  Serial.println(door,DEC);

}

void logalarmState(uint8_t level) {        //Log unlock events
  logDate();
  Serial.print("Alarm level changed to ");
  Serial.println(level,DEC);
}

void logalarmArmed(uint8_t level) {        //Log unlock events
  logDate();
  Serial.print("Alarm armed level changed to ");
  Serial.println(level,DEC);
}

void logprivFail() {
  //  Serial.println("Priv mode disabled");
  PROGMEMprintln(privsdeniedMessage);
}


void hardwareTest(long iterations)
{

  /* Hardware testing routing. Performs a read of all digital inputs and
   * a write to each relay output. Also reads the analog value of each
   * alarm pin. Use for testing hardware. Wiegand26 readers should read 
   * "HIGH" or "1" when connected.
   */

  for(uint8_t j=0; j<=7; j++) {
    pinMode(relayPins[j],OUTPUT);
  }

  for(long counter=1; counter<=iterations; counter++) {                                  // Do this number of times specified
    logDate();
    Serial.print("\n"); 
    Serial.println("Pass: "); 
    Serial.println(counter); 

    // Digital input testing
    Serial.print("R1 D0: ");
    Serial.println(digitalRead(2));
    Serial.print("R1 D1: ");
    Serial.println(digitalRead(3));
    Serial.print("R2 D0: ");
    Serial.println(digitalRead(19));
    Serial.print("R2 D0: ");
    Serial.println(digitalRead(18));      


    for(uint8_t p=0; p<=15; p++) {                                                          // Analog input testing
      Serial.print("Input ");
      Serial.print(p,DEC);
      Serial.print(": ");
      Serial.println(analogRead(analogsensorPins[p]));
    }



    Serial.println("RS485 port test begin");
    for(uint8_t i=0; i<=100; i++) {                                                        // RS-485 Serial port testing
      digitalWrite(16, HIGH);
      Serial3.print("Serial test ");
      Serial3.println(i, DEC);
      digitalWrite(16, LOW);
      delay(100);
    }
    Serial.println("RS485 port test end");  

    for(uint8_t o=0; o<=7; o++) {
      digitalWrite(relayPins[o],HIGH);                                                                 // Relay exercise routine
    }

    Serial.println("Relays on");
    delay(2000);

    for(uint8_t n=0; n<=7; n++) {
      digitalWrite(relayPins[n],LOW);
      delay(200);
    }
    Serial.println("Relays off");
    delay(200);
  }

  digitalWrite(4,LOW);      // Exercise the Wiegand reader output LED/buzzer pins
  digitalWrite(5,LOW);
  digitalWrite(6,LOW);
  digitalWrite(7,LOW);        
  digitalWrite(17,LOW);  
  delay(1000);
  digitalWrite(4,HIGH);
  digitalWrite(5,HIGH);
  digitalWrite(6,HIGH);
  digitalWrite(7,HIGH);        
  digitalWrite(17,HIGH);  
}

void clearUsers()    //Erases all users from EEPROM
{
  for(int i=EEPROM_FIRSTUSER; i<=EEPROM_LASTUSER; i++){
    EEPROM.write(i,0);  
    logDate();
    Serial.println("User database erased.");  
  }
}

void addnewkey(unsigned long tagNumber)
{
  unsigned long EEPROM_buffer=0;                                         // Buffer for recreating tagNumber from the 4 stored bytes.
  int found;

  logDate();
  found = checkUser(tagNumber);
  if (found >= 0){
    Serial.print("Key alredy exists in is slot:");
    Serial.println(found);
    return; 
  }

  for(int i=EEPROM_FIRSTUSER; i<=(EEPROM_LASTUSER-5); i=i+5)   // Find first empty key
  {


    EEPROM_buffer=0;
    EEPROM_buffer=(EEPROM.read(i+3));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+2));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+1));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i));


    if(EEPROM_buffer == 0xFFFFFFFF) {    
      logDate();
      found = (i-EEPROM_FIRSTUSER)/5;
      addUser(found, 1, tagNumber);
      break;
    }                             
  }
}  

void addUser(int userNum, uint8_t userMask, unsigned long tagNumber)       // Modifies a user an entry in the local database.
{                                                                       // Users number 0..NUMUSERS
  int offset = (EEPROM_FIRSTUSER+(userNum*5));                          // Find the offset to write this user to
  uint8_t EEPROM_buffer[5] ={0};                                        // Buffer for creating the 4 uint8_tvalues to write. Usermask is stored in uint8_t5.

  logDate();

  if((userNum <0) || (userNum > NUMUSERS)) {                            // Do not write to invalid EEPROM addresses.

    Serial.print("Invalid user modify attempted.");
  }
  else
  {

    EEPROM_buffer[0] = uint8_t(tagNumber &  0xFFF);   // Fill the buffer with the values to write to uint8_ts 0..4 
    EEPROM_buffer[1] = uint8_t(tagNumber >> 8);
    EEPROM_buffer[2] = uint8_t(tagNumber >> 16);
    EEPROM_buffer[3] = uint8_t(tagNumber >> 24);
    EEPROM_buffer[4] = uint8_t(userMask);

    for(int i=0; i<5; i++){
      EEPROM.write((offset+i), (EEPROM_buffer[i])); // Store the resulting value in 5 uint8_ts of EEPROM.

    }

    Serial.print("User number ");
    Serial.print(userNum,DEC);
    Serial.println(" successfully modified"); 

  }
}

void addUsermask(int userNum, uint8_t userMask)          // Modifies a user mask  in the local database.
{                                                                       // Users number 0..NUMUSERS
  int offset = (EEPROM_FIRSTUSER+(userNum*5));                          // Find the offset to write this user to
  uint8_t EEPROM_buffer = 255;                                           
  logDate();

  if((userNum <0) || (userNum > NUMUSERS)) {                            // Do not write to invalid EEPROM addresses.

    Serial.print("Invalid user modify attempted.");
  }
  else
  {

    EEPROM_buffer = uint8_t(userMask);

    EEPROM.write((offset+4), (EEPROM_buffer)); // Store the resulting value in 5 uint8_ts of EEPROM.

    Serial.print("User ");
    Serial.print(userNum,DEC);
    Serial.println(" mask successfully modified"); 

  }
}

void deleteUser(int userNum)                                            // Deletes a user from the local database.
{                                                                       // Users number 0..NUMUSERS
  int offset = (EEPROM_FIRSTUSER+(userNum*5));                          // Find the offset to write this user to

  logDate();

  if((userNum <0) || (userNum > NUMUSERS)) {                            // Do not write to invalid EEPROM addresses.

    Serial.print("Invalid user delete attempted.");
  }
  else
  {

    for(int i=0; i<5; i++){
      EEPROM.write((offset+i), 0xFF); // Store the resulting value in 5 bytes of EEPROM.
      // Starting at offset.

    }

    Serial.print("User deleted at position "); 
    Serial.println(userNum);

  }

}

int checkUser(unsigned long tagNumber)                                  // Check if a particular tag exists in the local database. Returns userMask if found.
{                                                                       // Users number 0..NUMUSERS
  // Find the first offset to check

  unsigned long EEPROM_buffer=0;                                         // Buffer for recreating tagNumber from the 4 stored bytes.
  int found=-1;

  logDate();
  if (checkSuperuser(tagNumber) >= 0) {
    return 5;
  }

  for(int i=EEPROM_FIRSTUSER; i<=(EEPROM_LASTUSER-5); i=i+5){

    EEPROM_buffer=0;
    EEPROM_buffer=(EEPROM.read(i+3));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+2));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+1));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i));

    if((EEPROM_buffer == tagNumber) && (tagNumber !=0xFFFFFFFF) && (tagNumber !=0x0)) {    // Return a not found on blank (0xFFFFFFFF) entries 
      logDate();
      Serial.print("User ");
      Serial.print(((i-EEPROM_FIRSTUSER)/5),DEC);
      Serial.println(" authenticated.");
      //found = EEPROM.read(i+4);
      // If found, return the user number
      found = (i-EEPROM_FIRSTUSER)/5;
      return found;
    }                             
  }

  Serial.println("User not found");
  delay(1000);                                                            // Delay to prevent brute-force attacks on reader
  return found;                        
}

int getUserMask(unsigned long tagNumber)                                  // Check if a particular tag exists in the local database. Returns userMask if found.
{                                                                       // Users number 0..NUMUSERS
  // Find the first offset to check

  unsigned long EEPROM_buffer=0;                                         // Buffer for recreating tagNumber from the 4 stored bytes.
  int found=-1;

  logDate();
  if (checkSuperuser(tagNumber) >= 0) {
    return 5;
  }

  for(int i=EEPROM_FIRSTUSER; i<=(EEPROM_LASTUSER-5); i=i+5){

    EEPROM_buffer=0;
    EEPROM_buffer=(EEPROM.read(i+3));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+2));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+1));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i));

    if((EEPROM_buffer == tagNumber) && (tagNumber !=0xFFFFFFFF) && (tagNumber !=0x0)) {    // Return a not found on blank (0xFFFFFFFF) entries 
      logDate();
      Serial.print("User ");
      Serial.print(((i-EEPROM_FIRSTUSER)/5),DEC);
      Serial.println(" authenticated.");
      // Return the usermask if found to function
      found = EEPROM.read(i+4);
      //found = (i-EEPROM_FIRSTUSER)/5;
      return found;
    }                             
  }

  Serial.println("User not found");
  delay(1000);                                                            // Delay to prevent brute-force attacks on reader
  return found;                        
}

void dumpUser(int usernum)                                            // Return information ona particular entry in the local DB
{                                                                      // Users number 0..NUMUSERS

  unsigned long EEPROM_buffer=0;                                       // Buffer for recreating tagNumber from the 4 stored bytes.

  if((0<=usernum) && (usernum <=NUMUSERS)){

    // Do something with usernumber ?
    int i=usernum*5+EEPROM_FIRSTUSER;

    EEPROM_buffer=0;
    EEPROM_buffer=(EEPROM.read(i+3));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+2));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+1));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i));

    // Print the Tag Doing X?
    Serial.print("User\t");
    Serial.print(((i-EEPROM_FIRSTUSER)/5),DEC);
    Serial.print("\t");
    Serial.print(EEPROM.read(i+4),DEC);
    Serial.print("\t");

    if(DEBUG>=2){
      //Serial.print((EEPROM_buffer >> 1) & 0xFFFFFF,DEC);
      //Serial.print("\t");
      Serial.println(EEPROM_buffer,HEX);
    }
    else {
      if(EEPROM_buffer != 0xFFFFFFFF) {
        Serial.print("********");
      }
    }

  }
  else Serial.println("Bad user number!");
}

/* sub parser for date updates
 */

int clockparse(char Data[]){
  uint8_t ok=0;
  uint8_t j=0;                                                          // Counters
  uint8_t k=0;
  uint8_t v[3] = {0,0,0};
  char ch=0;

  for (k = 0; k <= 9; k++)
  {
    ch = Data[k];
    if (ch == char(0)){
      break;
    }
    if ((ch >= '0') && (ch <= '9')) {
      v[j] = (v[j] * 10) + (byte(ch) - byte('0'));
    }
    else {
      switch(ch) {
      case ' ': 
        {
          break;
        }
      case ':': 
        {
          j++;
          ok = 1;
          break;
        }
      case '/': 
        {
          j++;
          ok = 2;
          break;
        }
      default: 
        {
          ok = 10;
        }  

      }
      if (ok > 4) {
        break;
      }
    }  
  }
  switch(ok){
  case 0:
    {                       // day of the week
      if ((v[0] > 0) && (v[0] < 8)) {
        dayOfWeek = v[0];
      }
      else {
        ok = 10;
      }
      break;
    } 
  case 1:
    {                        // Time
      if ((v[0] > 0) && (v[0] < 24)) {
        hour = v[0];
      }
      else {
        ok = 10;
        break;
      }
      if ((v[1] >= 0) && (v[1] < 60)) {
        minute = v[1];
      }
      else {
        ok = 10;
        break;
      }
      if ((v[2] >= 0) && (v[2] < 60)) {
        second = v[2];
      }
      else {
        ok = 10;
      }
      break; 
    }

  case 2:
    {                        // date
      if ((v[0] > 0) && (v[0] < 13)) {
        month = v[0];
      }
      else {
        ok = 10;
        break;
      }
      if ((v[1] > 0) && (v[1] < 32)) {
        dayOfMonth = v[1];
      }
      else {
        ok = 10;
        break;
      }
      if ((v[2] >= 0) && (v[2] < 99)) {
        year = v[2];
      }
      else {
        ok = 10;
      }
      break; 
    }
  default: 
    {
      ok = 10;
    }
  } 

  return ok;     

}

/* Displays a serial terminal menu system for
 * user management and other tasks
 */

void readCommand() {                                               

  uint8_t stringSize=(sizeof(inString)/sizeof(char));                    
  char cmdString[7][9];                              // Size of commands (7=number of items to parse, 9 = max length of each)
                                                     // 
  uint8_t j=0;                                       // Counters
  uint8_t k=0;
  char cmd=0;


  char ch;

  if (Serial.available()) {                                       // Check if user entered a command this round	                                  
    ch = Serial.read();                                            
    if( ch == '\r' || inCount >=stringSize-1)  {                   // Check if this is the terminating carriage return
      inString[inCount] = 0;
      inCount=0;
    }
    else{
      (inString[inCount++] = ch); 
    }

    if(DEBUG >0)
    {
      Serial.print(ch);                        // Turns echo on or off if enabled in DEBUG variable.
    }

    if(inCount==0) {
      for(uint8_t i=0;  i<stringSize; i++) {
        cmdString[j][k] = inString[i];
        if(k<9) k++;
        else break;

        if(inString[i] == ' ') // Check for space and if true, terminate string and move to next string.
        {
          cmdString[j][k-1]=0;
          if(j<7)j++;
          else break;
          k=0;             
        }

      }
      cmd = cmdString[0][0];

      switch(cmd) {


      case 'e': 
        {                                                 // Enable "privileged" commands at console
          logDate();

          if((consoleFail>=5) && (millis()-consolefailTimer<300000))  // Do not allow priv mode if more than 5 failed logins in 5 minute
          {  
            PROGMEMprintln(privsAttemptsMessage);
            break;
          }
          if (strtoul(cmdString[1],NULL,16) == PRIVPASSWORD)
          {
            consoleFail=0;                    
            PROGMEMprintln(privsenabledMessage);
            privmodeEnabled=true;
          }
          else {
            PROGMEMprintln(privsdisabledMessage);
            privmodeEnabled=false;                                          
            if(consoleFail==0) {                                   // Set the timeout for failed logins
              consolefailTimer=millis();
            }
            consoleFail++;                                    // Increment the login failure counter
          }

          break;

        }



      case 'a': 
        {                                                 // List whole user database
          if(privmodeEnabled==true) {                 
            logDate();
            Serial.println("User dump started.");
            Serial.print("UserNum:");
            Serial.print("\t");
            Serial.print("Usermask:");
            Serial.print("\t");
            Serial.println("TagNum:");

            for(int i=0; i<(NUMUSERS); i++){
              dumpUser(i);
              Serial.println();
            }
          }
          else{
            logprivFail();
          }
          break;
        }

      case 's': 
        {                                                 // List user 
          if(privmodeEnabled==true) {
            Serial.print("UserNum:");
            Serial.print(" ");
            Serial.print("Usermask:");
            Serial.print(" ");
            Serial.println("TagNum:");
            dumpUser(atoi(cmdString[1]));
            Serial.println();
          }
          else{
            logprivFail();
          }
          break;
        }
                 
     case 'd': {                                                 // Display current time
                   logDate();
                   Serial.println();
                   break;
                            }

      case '1': 
        {                                               // Deactivate alarm                                       
          if(privmodeEnabled==true) {
            armAlarm(0);
            alarmState(0);
            chirpAlarm(1);  
          }
          else{
            logprivFail();
          }
          break;
        }
      case '2': 
        {                                               // Activate alarm with delay.
          chirpAlarm(20);                                          // 200 chirps = ~30 seconds delay
          armAlarm(1);                           
          break; 
        } 

      case 'u': 
        {
          if(privmodeEnabled==true) {
            alarmState(0);                                       // Set to door chime only/open doors                                                          

            armAlarm(4);
            doorUnlock(1);
            doorUnlock(2);
            door1Locked=false;
            door2Locked=false;
            chirpAlarm(3);   
          }

          else{
            logprivFail();
          }
          break;  
        }
      case 'l': 
        {                                             // Lock all doors          
          lockall();
          chirpAlarm(1);   
          break;  
        }                            

      case '3': 
        {                                            // Train alarm sensors
          if(privmodeEnabled==true) {
            trainAlarm();
          }
          else{
            logprivFail();
          }
          break;
        }
      case '9': 
        {                                            // Show site status
          PROGMEMprint(statusMessage1);
          Serial.println(alarmArmed,DEC);
          PROGMEMprint(statusMessage2);
          Serial.println(alarmActivated,DEC);
          PROGMEMprint(statusMessage3);
          Serial.println(pollAlarm(3),DEC);
          PROGMEMprint(statusMessage4);
          Serial.println(pollAlarm(2),DEC);                  
          PROGMEMprint(statusMessage5); 
          Serial.println(door1Locked);                    
          PROGMEMprint(statusMessage6); 
          Serial.println(door2Locked); 
          PROGMEMprint(statusMessage7);
          // This doesn't seem to work - ?
          Serial.print((0.01958*analogRead(15)),2);          // Pin 15 has a 4:1 voltage divider. Reads 0..1024 for 0..20V input at terminals.
          //Serial.print((analogRead(15)),2);          // Pin 15 has a 4:1 voltage divider. Reads 0..1024 for 0..20V input at terminals.
          Serial.println('V');
          break;
        }

      case 'o': 
        {  
          if(privmodeEnabled==true) {
            if(atoi(cmdString[1]) == 1){                                     
              alarmState(0);                                       // Set to door chime only/open doors                                                          

              armAlarm(4);
              doorUnlock(1);                                       // Open the door specified
              door1locktimer=millis();
              break;
            }                    
            if(atoi(cmdString[1]) == 2){  
              alarmState(0);                                       // Set to door chime only/open doors                                                          

              armAlarm(4);
              doorUnlock(2);                                        
              door2locktimer=millis();
              break;               
            }
            Serial.print("Invalid door number!");
          }

          else{
            logprivFail();
          }
          break;
        } 

      case 'r': 
        {                                                 // Remove a user
          if(privmodeEnabled==true) {
            dumpUser(atoi(cmdString[1]));
            deleteUser(atoi(cmdString[1]));
          }
          else{
            logprivFail();
          }
          break; 
        }              

      case 'm': 
        {                                                                // Add/change a user                   
          if(privmodeEnabled==true) {
            dumpUser(atoi(cmdString[1]));
            addUser(atoi(cmdString[1]), atoi(cmdString[2]), strtoul(cmdString[3],NULL,16));                
            dumpUser(atoi(cmdString[1]));
          }
          else{
            logprivFail();
          }                                    

          break;
        }
        
      case 'n': 
        {                                                                // Add a new user to the first open slot with a default usermask                 
          if(privmodeEnabled==true) {
            addnewkey(strtoul(cmdString[1],NULL,16));                
            //dumpUser(return);
          }
          else{
            logprivFail();
          }                                    

          break;
        }
        
      case 't': 
        {                                                                // set the date/time 
          if(privmodeEnabled==true) {
            Serial.print("Old time: ");           
            logDate();
            Serial.println();
            second = atoi(cmdString[1]);
            minute = atoi(cmdString[2]);
            hour = atoi(cmdString[3]);
            dayOfWeek = atoi(cmdString[4]);
            dayOfMonth = atoi(cmdString[5]);
            month = atoi(cmdString[6]);
            year = atoi(cmdString[7]);
            if(DEBUG >= 2) {    
            Serial.print("Your input: ");
            Serial.print(hour, DEC);
            Serial.print(":");
            Serial.print(minute, DEC);
            Serial.print(":");
            Serial.print(second, DEC); 
            Serial.print(" ");
            Serial.print(month, DEC);
            Serial.print("/");
            Serial.print(dayOfMonth, DEC);
            Serial.print("/");          
            //Serial.print(cmdString[7]);
            //Serial.println(atoi(cmdString[7]), DEC);
            Serial.print(year, DEC); 
            Serial.print(" DOW:");
            Serial.println(dayOfWeek, DEC);
            }                
            ds1307.setDateDs1307(second, minute, hour, dayOfWeek, dayOfMonth, month, year);
            Serial.print("New time: ");
            logDate();
            Serial.println();
          }
          else{
            logprivFail();
          }                                    

          break;
        }

      case 'h': 
        {
          if(privmodeEnabled==true) {        // Perform hardware test
            hardwareTest(1);  
          }

          else{
            logprivFail();
          }
          break;  
        } 

      case 'b': 
        {
          if(privmodeEnabled==true) {        // You can ring my bell, ring my bell.
                 logDate();
                 Serial.print("You can ring my bell, ring my bell...");
                 Serial.println();
                 digitalWrite(ALARMSTROBEPIN, HIGH);
                 delay(100);
                 digitalWrite(ALARMSTROBEPIN, LOW);
                 delay(80);
                 digitalWrite(ALARMSTROBEPIN, HIGH);
                 delay(100);
                 digitalWrite(ALARMSTROBEPIN, LOW);
                 delay(80);
                 digitalWrite(ALARMSTROBEPIN, HIGH);
                 delay(100);
                 digitalWrite(ALARMSTROBEPIN, LOW);
                 delay(80);        
                 Serial.println("Bell ring complete...");
          }

          else{
            logprivFail();
          }
          break;  
        } 


      case '?': 
        {                                                  // Display help menu
          PROGMEMprintln(consolehelpMessage1);
          PROGMEMprintln(consolehelpMessage2);
          PROGMEMprintln(consolehelpMessage3);
          PROGMEMprintln(consolehelpMessage4);
          PROGMEMprintln(consolehelpMessage5);                     
          PROGMEMprintln(consolehelpMessage6);                  
          PROGMEMprintln(consolehelpMessage7); 
          PROGMEMprintln(consolehelpMessage8);
          PROGMEMprintln(consolehelpMessage9);
          PROGMEMprintln(consolehelpMessage10);
          PROGMEMprintln(consolehelpMessage11);
          PROGMEMprintln(consolehelpMessage12);
          break;
        }

      default:  
        PROGMEMprintln(consoledefaultMessage);
        break;
      }  

    }                                    // End of 'if' statement for Serial.available
  }                                     // End of 'if' for string finished
}                                      // End of function 




/* Wrapper functions for interrupt attachment
 Could be cleaned up in library?
 */
void callReader1Zero(){
  wiegand26.reader1Zero();
}
void callReader1One(){
  wiegand26.reader1One();
}
void callReader2Zero(){
  wiegand26.reader2Zero();
}
void callReader2One(){
  wiegand26.reader2One();
}
void callReader3Zero(){
  wiegand26.reader3Zero();
}
void callReader3One(){
  wiegand26.reader3One();
}



