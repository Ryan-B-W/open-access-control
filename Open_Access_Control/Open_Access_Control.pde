/*
 * Open Source RFID Access Controller
 *
 * 2/14/2011 v1.25
 * Arclight - arclight@23.org
 * Danozano - danozano@gmail.com
 *
 * For latest downloads, including Eagle CAD files for the hardware, check out
 * http://code.google.com/p/open-access-control/downloads/list
 *
 * Latest update fixes pin assignments to line up with new hardware design
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
 *
 */

#include <Wire.h>         // Needed for I2C Connection to the DS1307 date/time chip
#include <EEPROM.h>       // Needed for saving to non-voilatile memory on the Arduino.

#include <Ethernet.h>     // Ethernet stuff, comment out if not used.
#include <SPI.h>          
#include <Server.h>
#include <Client.h>

#include <DS1307.h>       // DS1307 RTC Clock/Date/Time chip library
#include <WIEGAND26.h>    // Wiegand 26 reader format libary
#include <PCATTACH.h>     // Pcint.h implementation, allows for >2 software interupts.


/* Static user List - Implemented as an array for testing or small installations.
 */

#define queeg      111111       // Name and badge number in HEX. We are not using checksums or site ID, just the whole
                                // output string from the reader.
#define arclight   0x14B949D    
#define kallahar   0x2B46B62
#define danozano   0x3909D3
#define flea       0x5555555

long  superUserList[] = { arclight,danozano,kallahar,queeg,flea};  // Super user table (cannot be changed by software)


#define DOORDELAY 2500                  // How long to open door lock once access is granted. (2500 = 2.5s)
#define SENSORTHRESHOLD 50             // Analog sensor change that will trigger an alarm (0..255)

#define EEPROM_ALARM 0                  // EEPROM address to store alarm state between reboots (0..511)
#define EEPROM_ALARMARMED 1             // EEPROM address to store alarm armed state between reboots
#define EEPROM_ALARMZONES 20            // Starting address to store "normal" analog values for alarm zone sensor reads.
#define KEYPADTIMEOUT 5000              // Timeout for pin pad entry.

#define EEPROM_FIRSTUSER 24
#define EEPROM_LASTUSER 1024
#define NUMUSERS  ((EEPROM_LASTUSER - EEPROM_FIRSTUSER)/5)  //Define number of internal users (200 for UNO/Duemillanova)


#define DOORPIN1 relayPins[2]           // Define door 1 pin
#define DOORPIN2 relayPins[1]           // Define door 2 pin
#define ALARMSTROBEPIN relayPins[0]     // Define the reader LED pin
#define ALARMSIRENPIN relayPins[3]      // Define the alarm siren pin

byte reader1Pins[]={2,3};               // Reader 1 connected to pins 4,5
byte reader2Pins[]= {4,5};              // Reader2 connected to pins 6,7

//byte reader3Pins[]= {10,11};                // Reader3 connected to pins X,Y (Not implemented on v2.x Access Control Board)

const byte analogsensorPins[] = {0,1,2,3};    // Alarm Sensors connected to other analog pins
const byte relayPins[]= {6,7,8,9};            // Relay output pins

bool door1Locked=true;                        //Keeps track of whether the doors are supposed to be locked right now
bool door2Locked=true;

long door1locktimer=0;                        //Keep track of when door is supposed to be relocked
long door2locktimer=0;

long chimeDelay=0;                            // Keep track of when door chime last activated
long alarmDelay=0;                             // Keep track of alarm delay action

#define numUsers (sizeof(superUserList)/sizeof(long))                  //User access array size (used in later loops/etc)
#define NUMDOORS (sizeof(doorPin)/sizeof(byte))
#define numAlarmPins (sizeof(analogsensorPins)/sizeof(byte))

//Other global variables
byte second, minute, hour, dayOfWeek, dayOfMonth, month, year;  // RTC clock variables

byte alarmActivated = EEPROM.read(EEPROM_ALARM);                   // Read the last alarm state as saved in eeprom.
byte alarmArmed = EEPROM.read(EEPROM_ALARMARMED);                  // Alarm level variable (0..5, 0==OFF) 
boolean sensor[4]={false};                                             // Keep track of tripped sensors, do not log again until reset.

// Enable up to 3 door access readers.
volatile long reader1 = 0;
volatile int  reader1Count = 0;
volatile long reader2 = 0;
volatile int  reader2Count = 0;
//volatile long reader3 = 0;                // Uncomment if using a third reader.
//volatile int  reader3Count = 0;

long keypadTime = 0;                                  // Timeout counter for  reader with key pad
long keypadValue=0;


// Serial terminal buffer (needs to be global)
char inString[40]={0};                                             // Size of command buffer (<=128)
byte inCount=0;

/* Create an instance of the various C++ libraries we are using.
 */

DS1307 ds1307;        // RTC Instance
WIEGAND26 wiegand26;  // Wiegand26 (RFID reader serial protocol) library
PCATTACH pcattach;    // Software interrupt library



void setup(){           // Runs once at Arduino boot-up


    Wire.begin();   // start Wire library as I2C-Bus Master

  /* Attach pin change interrupt service routines from the Wiegand RFID readers
   */
  pcattach.PCattachInterrupt(reader1Pins[0], callReader1Zero, CHANGE); 
  pcattach.PCattachInterrupt(reader1Pins[1], callReader1One,  CHANGE);  
  pcattach.PCattachInterrupt(reader2Pins[1], callReader2One,  CHANGE);
  pcattach.PCattachInterrupt(reader2Pins[0], callReader2Zero, CHANGE);

  //Clear and initialize readers
  wiegand26.initReaderOne(); //Set up Reader 1 and clear buffers.
  wiegand26.initReaderTwo(); 


  //Initialize output relays

  for(byte i=0; i<4; i++){        
    pinMode(relayPins[i], OUTPUT);                                                      
    digitalWrite(relayPins[i], LOW);                  // Sets the relay outputs to LOW (relays off)
  }


 //ds1307.setDateDs1307(0,18,22,2,12,10,10);         
  /*  Sets the date/time (needed once at commissioning)
   
   byte second,        // 0-59
   byte minute,        // 0-59
   byte hour,          // 1-23
   byte dayOfWeek,     // 1-7
   byte dayOfMonth,    // 1-28/29/30/31
   byte month,         // 1-12
   byte year);          // 0-99
   */



  Serial.begin(57600);	               	       //Set up Serial output at 8,N,1,57,600bps
  logReboot();
  chirpAlarm(1,ALARMSIRENPIN);                 //Chirp the alarm to show system ready.

//  hardwareTest(100);                         // IO Pin testing routing (use to check your inputs with hi/lo +(5-12V) sources)
                                               // Also checks relays


}
void loop()                                     // Main branch, runs over and over again
{                         

readCommand();                                 //Check for user serial commands

  
  /* Check if doors are supposed to be locked and lock/unlock them 
   * if needed.
   */

  if(((millis() - door1locktimer) >= DOORDELAY) && door1locktimer !=0)
  { 
    if(door1Locked==true){
    doorLock(1);
    door1locktimer=0;
                          }

  }

  if(((millis() - door2locktimer) >= DOORDELAY) && door2locktimer !=0)
  { 
    if(door2Locked==true) {
     doorLock(2); 
     door2locktimer=0;
                           }
   
  }   

 if(door1Locked==false) {       // Unlock doors if door supposed to be unlocked.
      doorUnlock(1); 
                        }
 if(door2Locked==false) {
      doorUnlock(1); 
                        }             


  /* Check physical sensors with 
   the logic below. Behavior is based on
   the current alarmArmed value.
   0=disarmed 
   1=armed
   2=
   3=
   4=door chime only (Unlock DOOR1, Check zone 0/chirp alarm if active)
   
   */



  switch(alarmArmed) {

 case 0:
  {
    break;                                        // Alarm is not armed, do nothing.  
  }

    case 1:                                       // Alarm is armed
  {
                                              
                                                    
      if(alarmActivated==0){                       // If alarm is armed but not currently alrming, check sensor zones.

          if(pollAlarm(0) == 1 ){                  // If this zone is tripped, immediately set Alarm State to 1 (alarm immediate).                                
            alarmState(1);                        

             if(sensor[0]==false) {            // Only log and save if sensor activation is new.
              logalarmSensor(0);
              EEPROM.write(EEPROM_ALARM,0);    // Save the alarm sensor tripped to eeprom                                    
              sensor[0]=true;               // Set value to not log this again
            }
          }                 
          if(pollAlarm(1) == 1 ){                   // If this zone is tripped, immediately set Alarm State to 2 (alarm delay).
              alarmState(2);                        // Also starts the delay timer    
              alarmDelay=millis();
              if(sensor[1]==false) {                // Only log and save if sensor activation is new.
               logalarmSensor(1);
               EEPROM.write(EEPROM_ALARM,1);        // Save the alarm sensor tripped to eeprom                                      
               sensor[1]=true;                     // Set value to not log this again                                                                        
              }
           }                                                                                                    
  
          if(pollAlarm(2) == 1 ){                  // If this zone is tripped, immediately set Alarm State to 1 (alarm immediate).
            alarmState(1);      
             if(sensor[2]==false) {            // Only log and save if sensor activation is new.
              logalarmSensor(2);
              EEPROM.write(EEPROM_ALARM,2);    // Save the alarm sensor tripped to eeprom                                     
              sensor[2]=true;               // Set value to not log this again
             }
           }                              

          if(pollAlarm(3) == 1 ){                  // If this zone is tripped, log the action only
            if(sensor[3]==false) {
             logalarmSensor(3);   
                                                                               
            sensor[3]=true;                       // Set value to not log this again          
             }
           }
       }
                                                    
   if(alarmActivated==2)  {                         // If alarm is activated on delay, take this action
    if(millis()-alarmDelay >=60000)
     {
      alarmState(1);                          
     }
                           }  
    
    
      break;
  }
  
  case 4: 
    {                 //Door chime mode
      
      if(pollAlarm(1) !=0 && millis()-chimeDelay >=10000) {   // Only activate door chime every 10sec or more
        chirpAlarm(3,ALARMSIRENPIN);                  
        logChime();
        chimeDelay = millis();   
         }
        break;    
      
    }

  default: 
    {
      break;  
    }
  }




  // Notes: RFID polling is interrupt driven, just test for the reader1Count value to climb to the bit length of the key
  // change reader1Count & reader1 et. al. to arrays for loop handling of multiple reader output events
  // later change them for interrupt handling as well!
  // currently hardcoded for a single reader unit

  /* This code checks a reader with a 26-bit keycard input and a keypad. Use the second routine for 
   readers without keypads.  A 5-second window for commands is opened after each successful key access read.
   */


  if(reader1Count >= 26){                                //  tag presented to reader1
    logTagPresent(reader1,1);                            //  write log entry to serial port
    //  CHECK TAG IN OUR LIST OF USERS. -255 = no match
    if((checkSuperuser(reader1) > 0) ||checkUser(reader1) >0)
    {                                                    //  if > 0 there is a match. checkSuperuser (reader1) is the userList () index 
      logAccessGranted(reader1, 1);                      //  log and unlock door 1

        if(alarmArmed !=0){ 
        alarmArmed =0;
        alarmState(0);                                       // Deactivate Alarm if armed. (Must do this _before_unlocking door.
      }                                            

      doorUnlock(1);                                           // Unlock the door.
      door1locktimer=millis();
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
          else break;

        }

      }
      if(keypadValue !=0){
        logkeypadCommand(1,keypadValue);
        runCommand(keypadValue);                              // Run any commands entered at the keypads.
        wiegand26.initReaderOne();
      }

    }
    else if(checkSuperuser(reader1) !=1) {           // If no user match, log entry written
      logAccessDenied(reader1,1);                 // no tickee, no laundree
    }

    wiegand26.initReaderOne();

  }                      



  if(reader2Count >= 26){                           //  tag presented to reader2 (No keypad on this reader)
    logTagPresent(reader2,2);                       //  write log entry to serial port

    if((checkSuperuser(reader2) > 0) ||checkUser(reader2) >0) {                // If > 0 there is a match. 
      logAccessGranted(reader2, 2);                // Log and unlock door 2
 

      //  CHECK TAG IN OUR LIST OF USERS. -255 = no match
      if(alarmActivated !=0){

      
      alarmState(0);                            //  Deactivate Alarm
      }

     door2locktimer=millis();
      doorUnlock(2);                        // Unlock the door.
    }
    else if(checkSuperuser(reader2) !=1) {           //  no match, log entry written
      logAccessDenied(reader2,2);                 //  no tickee, no laundree
    }

    wiegand26.initReaderTwo();                   //  Reset for next tag scan

  }


  } // End of loop()

void runCommand(long command) {         // Run any commands entered at the pin pad.

  switch(command) {                              

  case 0x0: 
    {                                   // If command = 0, do nothing
      break;
    }        

  case 0x1: 
    {                                     // If command = 1, deactivate alarm
      alarmState(0);                    // Set global alarm level variable
      armAlarm(0);
      chirpAlarm(1,ALARMSIRENPIN);
      break;  
    }

  case 0x2: 
    {                                   // If command =2, activate alarm with delay.
      chirpAlarm(20,ALARMSIRENPIN);                  // 200 chirps = ~30 seconds delay
      armAlarm(1);                    
      break; 
    }        
  case 0x3: 
    {
      armAlarm(4);                   // Set to door chime only
      chirpAlarm(3,ALARMSIRENPIN);   
      break;  
    }
  case 0x4:
    {
      chirpAlarm(4,ALARMSIRENPIN);
      break;
    }

  case 0x911: 
    {
      chirpAlarm(9,ALARMSIRENPIN);          // Emergency
      armAlarm(1);                   
      alarmState(1);
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

void alarmState(byte alarmLevel) {                    //Changes the alarm status based on this flow

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
      digitalWrite(ALARMSTROBEPIN, HIGH);          
      alarmActivated = alarmLevel;                    //Set global alarm level variable
      break;  
    }        

  case 2:                                        
    {
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
     }
     
     case 5: {
     vaporize_intruders(MAIM);
     }  etc. etc. etc.
     */

  default: 
    {                                            // Exceptional cases kill alarm outputs
      digitalWrite(ALARMSIRENPIN, LOW);          // Turn off siren and strobe
      digitalWrite(ALARMSTROBEPIN, LOW);        
    }  

  }

}  //End of alarmState()

void chirpAlarm(byte chirps, byte pin){            // Chirp the siren pin or strobe to indicate events.      
  for(byte i=0; i<chirps; i++) {
    digitalWrite(pin, HIGH);
    delay(100);
    digitalWrite(pin, LOW);
    delay(200);                              
  }    
}                                   

byte pollAlarm(byte input){

  // Return 1 if sensor shows < pre-defined voltage.
  if(abs((analogRead(analogsensorPins[input])/4) - EEPROM.read(EEPROM_ALARMZONES+input)) >SENSORTHRESHOLD){
     return 1;

  }
  else return 0;
}

void trainAlarm(){                       // Train the system about the default states of the alarm pins.
  armAlarm(0);                           // Disarm alarm first
  alarmState(0);

  int temp[5]={0};
  int avg;

  logtrainAlarm();
  for(int i=0; i<numAlarmPins; i++) {         

    for(int j=0; j<5;j++){                          
      temp[j]=analogRead(analogsensorPins[i]);
      delay(20);                                         // Give the readings time to settle
    }
    avg=((temp[0]+temp[1]+temp[2]+temp[3]+temp[4])/20);  // Average the results to get best values
    Serial.print("Sensor ");
    Serial.print(i);
    Serial.print(" ");
    Serial.print("value:");
    Serial.println(avg);
    EEPROM.write((EEPROM_ALARMZONES+i),byte(avg));   //Save results to EEPROM
    avg=0;
  }



}

void armAlarm(byte level){                       // Arm the alarm and set to level
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

int checkSuperuser(long input){       // Check to see if user is in the user list. If yes, return their index value.
  for(int i=0; i<=numUsers; i++){   
    if(input == superUserList[i]){
      logDate();
      Serial.print("Superuser");
      Serial.print(i,DEC);
      Serial.print(" found in table.");
      return(i);
    }
  }                   
  return -255;             //If no, return -255
}

int disableKey(long input){       //Set user key to negative value if we need to expire.
  for(int i=0; i<numUsers; i++){   
    if(superUserList[i] == input){
      superUserList[i] *= -1;
      return(1);
    }                                  
    else return -255;          
  }   //If not found, return -255
}


void doorUnlock(int input) {          //Send an unlock signal to the door and flash the Door LED
byte dp=1;
  if(input == 1) dp=DOORPIN1;
   else(dp =DOORPIN2);
  
  digitalWrite(dp, HIGH);
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" unlocked");

}

void doorLock(int input) {          //Send an unlock signal to the door and flash the Door LED
byte dp=1;
  if(input == 1) dp=DOORPIN1;
   else(dp =DOORPIN2);

  digitalWrite(dp, LOW);
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" locked");

}
void lockall() {                      //Lock down all doors. Can also be run periodically to safeguard system.

  digitalWrite(DOORPIN1, LOW);
  digitalWrite(DOORPIN2,LOW);
  door1Locked==true;
  door2Locked==true;
  Serial.print("All Doors ");
  Serial.println(" relocked");
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
  Serial.print(' ');
  
  switch(dayOfWeek){

    case 1:{
     Serial.print("SUN");
     break;
           }
    case 2:{
     Serial.print("MON");
     break;
           }
    case 3:{
     Serial.print("TUE");
     break;
          }
    case 4:{
     Serial.print("WED");
     break;
           }
    case 5:{
     Serial.print("THU");
     break;
           }
    case 6:{
     Serial.print("FRI");
     break;
           }
    case 7:{
     Serial.print("SAT");
     break;
           }  
  }
  
  Serial.print(" ");

}

void logReboot() {                                  //Log system startup
  logDate();
  Serial.println("Open Access Control System rebooted.");
}

void logChime() {
  logDate();
  Serial.println("Door opened.");
}

void logTagPresent (long user, byte reader) {     //Log Tag Presented events
  logDate();
  Serial.print("User ");
  Serial.print(user,DEC);
  Serial.print(" presented tag at reader ");
  Serial.println(reader,DEC);
}

void logAccessGranted(long user, byte reader) {     //Log Access events
  logDate();
  Serial.print("User ");
  Serial.print(user,DEC);
  Serial.print(" granted access at reader ");
  Serial.println(reader,DEC);
}                                         

void logAccessDenied(long user, byte reader) {     //Log Access denied events
  logDate();
  Serial.print("User ");
  Serial.print(user,DEC);
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
  Serial.print(user,DEC);
  Serial.print(" unlocked door ");
  Serial.println(door,DEC);

}

void logalarmState(byte level) {        //Log unlock events
  logDate();
  Serial.print("**Alarm level changed to ");
  Serial.println(level,DEC);
}

void logalarmArmed(byte level) {        //Log unlock events
  logDate();
  Serial.print("**Alarm armed level changed to ");
  Serial.println(level,DEC);
}
/* Wrapper functions for interrupt attachment
 Could be cleaned up in library?
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


void hardwareTest(long iterations)
{

  /* Hardware testing routing. Performs a read of all digital inputs and
   * a write to each relay output. Also reads the analog value of each
   * alarm pin. Use for testing hardware. Wiegand26 readers should read 
   * "HIGH" or "1" when connected.
   */

  pinMode(2,INPUT);
  pinMode(3,INPUT);
  pinMode(4,INPUT);
  pinMode(5,INPUT);

  pinMode(6,OUTPUT);
  pinMode(7,OUTPUT);
  pinMode(8,OUTPUT);
  pinMode(9,OUTPUT);

  for(long counter=1; counter<=iterations; counter++) {                                  // Do this numebr of times specified
    logDate();
    Serial.print("\n"); 
    Serial.println("Pass: "); 
    Serial.println(counter); 
    Serial.print("Input 2:");                    // Digital input testing
    Serial.println(digitalRead(2));
    Serial.print("Input 3:");
    Serial.println(digitalRead(3));
    Serial.print("Input 4:");
    Serial.println(digitalRead(4));
    Serial.print("Input 5:");
    Serial.println(digitalRead(5));
    Serial.print("Input A0:");                   // Analog input testing
    Serial.println(analogRead(0));
    Serial.print("Input A1:");
    Serial.println(analogRead(1));
    Serial.print("Input A2:");
    Serial.println(analogRead(2));
    Serial.print("Input A3:");
    Serial.println(analogRead(3));
    delay(5000);

    digitalWrite(6,HIGH);                         // Relay exercise routine
    digitalWrite(7,HIGH);
    digitalWrite(8,HIGH);
    digitalWrite(9,HIGH);
    Serial.println("Relays 0..3 activated");
    delay(2000);
    digitalWrite(6,LOW);
    digitalWrite(7,LOW);
    digitalWrite(8,LOW);
    digitalWrite(9,LOW);
    Serial.println("Relays 0..3 deactivated");

  }
}

void clearUsers()    //Erases all users from EEPROM
{
  for(int i=EEPROM_FIRSTUSER; i<=EEPROM_LASTUSER; i++){
    EEPROM.write(i,0);  
    logDate();
    Serial.println("User database erased.");  
  }
}

void addUser(int userNum, byte userMask, unsigned long tagNumber)       // Inserts a new users into the local database.
{                                                                       // Users number 0..NUMUSERS
  int offset = (EEPROM_FIRSTUSER+(userNum*5));                           // Find the offset to write this user to
  byte EEPROM_buffer[] ={
    0,0,0,0,0  };                                                       // Buffer for creating the 4 byte values to write. Usermask is store in byte 5.

  logDate();

  if((userNum <0) || (userNum > NUMUSERS)) {                            // Do not write to invalid EEPROM addresses.

    Serial.print("Invalid user modify attempted.");
  }
  else
  {




    EEPROM_buffer[0] = byte(tagNumber &  0xFFF);   // Fill the buffer with the values to write to bytes 0..4 
    EEPROM_buffer[1] = byte(tagNumber >> 8);
    EEPROM_buffer[2] = byte(tagNumber >> 16);
    EEPROM_buffer[3] = byte(tagNumber >> 24);
    EEPROM_buffer[4] = byte(userMask);



    for(int i=0; i<5; i++){
      EEPROM.write((offset+i), (EEPROM_buffer[i])); // Store the resulting value in 5 bytes of EEPROM.

    }

    Serial.print("User ");
    Serial.print(userNum,DEC);
    Serial.println(" successfully modified"); 


  }
}

void deleteUser(int userNum)     // Deletes a user from the local database.
{                                                                       // Users number 0..NUMUSERS
  int offset = (EEPROM_FIRSTUSER+(userNum*5));                          // Find the offset to write this user to
  byte EEPROM_buffer[] ={0xFF,0xFF,0xFF,0xFF,0xFF  };                   // Buffer for creating the 4 byte values to write. Usermask is store in byte 5.

  logDate();

  if((userNum <0) || (userNum > NUMUSERS)) {                            // Do not write to invalid EEPROM addresses.

    Serial.print("Invalid user delete attempted.");
  }
  else
  {



    for(int i=0; i<5; i++){
      EEPROM.write((offset+i), (EEPROM_buffer[i])); // Store the resulting value in 5 bytes of EEPROM.
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

  logDate();


  for(int i=EEPROM_FIRSTUSER; i<=(EEPROM_LASTUSER-5); i=i+5){


    EEPROM_buffer=0;
    EEPROM_buffer=(EEPROM.read(i+3));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+2));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+1));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i));


    if(EEPROM_buffer == tagNumber) {
      logDate();
      Serial.print("User located at position ");
      Serial.println(((i-EEPROM_FIRSTUSER)/5),DEC);
      return(EEPROM.read(i+4));

    }                             

  }
  Serial.println("User not found");
  return(-255);                        
}


void dumpUsers()                                                        // Displays a lsit of all users in internal DB
{                                                                       // Users number 0..NUMUSERS


  unsigned long EEPROM_buffer=0;                                         // Buffer for recreating tagNumber from the 4 stored bytes.

  logDate();
  Serial.println("User dump started.");
  Serial.print("UserNum:");
  Serial.print("\t");
  Serial.print("Usermask:");
  Serial.print("\t");
  Serial.println("TagNum:");


  for(int i=EEPROM_FIRSTUSER; i<=(EEPROM_LASTUSER-5); i=i+5){


    EEPROM_buffer=0;
    EEPROM_buffer=(EEPROM.read(i+3));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+2));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+1));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i));



    Serial.print(((i-EEPROM_FIRSTUSER)/5),DEC);
    Serial.print("\t");
    Serial.print(EEPROM.read(i+4),DEC);
    Serial.print("\t");
    Serial.println(EEPROM_buffer,DEC);
  }
}


void dumpUser(byte usernum)                                            // Displays a lsit of all users in internal DB
{                                                                      // Users number 0..NUMUSERS


  unsigned long EEPROM_buffer=0;                                       // Buffer for recreating tagNumber from the 4 stored bytes.


  Serial.print("UserNum:");
  Serial.print("\t");
  Serial.print("Usermask:");
  Serial.print("\t");
  Serial.println("TagNum:");
  if(0<=usernum && usernum <=199){

    int i=usernum*5+EEPROM_FIRSTUSER;

    EEPROM_buffer=0;
    EEPROM_buffer=(EEPROM.read(i+3));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+2));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+1));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i));



    Serial.print(((i-EEPROM_FIRSTUSER)/5),DEC);
    Serial.print("\t");
    Serial.print(EEPROM.read(i+4),DEC);
    Serial.print("\t");
    Serial.println(EEPROM_buffer,DEC);


  
  }
  else Serial.println("Bad user number!");
}
void readCommand() {                                               // Displays a serial terminal menu system for
                                                                   // user management and other tasks

byte stringSize=(sizeof(inString)/sizeof(char));                    
char cmdString[4][10];                                             // Size of commands (4=number of items to parse, 10 = max length of each)
                                               
byte j=0;                                                          // Counters
byte k=0;
char cmd=0;

char ch;

 if (Serial.available()) {                                       // Check if user entered a command this round	                                  
  ch = Serial.read();
  if( ch == '\r' || inCount >=stringSize-1)  { // is this the terminating carriage return
   inString[inCount] = 0;
   inCount=0;
                         }
  else{
  (inString[inCount++] = ch); }
  Serial.print(ch);


if(inCount==0) {
  for(byte i=0;  i<stringSize; i++) {
    cmdString[j][k] = inString[i];
    if(k<9) k++;
    else break;
 
    if(inString[i] == ' ') // Check for space and if true, terminate string and move to next string.
    {
      cmdString[j][k-1]=0;
      if(j<3)j++;
      else break;
      k=0;             
    }

  }


  

cmd = cmdString[0][0];
                                       
               switch(cmd) {

                 case 'a': {                                                 // List whole user database
                  dumpUsers();
                  break;
                           }
                 case 's': {                                                 // List user 
                  dumpUser(atoi(cmdString[1]));
                  break;
                           }
 
                  case 'd': {                                                 // Display current time
                   logDate();
                   Serial.println();
                   break;
                            }
                  case '1': {                                               // Deactivate alarm                                       
                   armAlarm(0);
                   alarmState(0);
                   chirpAlarm(1,ALARMSIRENPIN);  
                   break;
                            }
                  case '2': {                                               // Activate alarm with delay.
                   chirpAlarm(20,ALARMSIRENPIN);                            // 200 chirps = ~30 seconds delay
                   armAlarm(1);                    
                   break; 
                            } 
                  case 'u': {
                   alarmState(0);                                       // Set to door chime only/open doors                                                                       
                   armAlarm(4);
                   doorUnlock(1);
                   doorUnlock(2);
                   door1Locked==false;
                   door2Locked==false;
                   chirpAlarm(3,ALARMSIRENPIN);   
                   break;  
                            }
                  case 'l': {
                                                                           // Lock all doors
                   lockall();
                   chirpAlarm(1,ALARMSIRENPIN);   
                   break;  
                            }                            
                   case '3': {                                            // Train alarm sensors
                   trainAlarm();
                   break;
                             }
                  case 'o': {  
                    if(atoi(cmdString[1]) == 1){                                     
                    doorUnlock(1);                                  // Open the door specified
                    door1locktimer=millis();
                                          }                    
                    if(atoi(cmdString[1]) == 2){  
                     doorUnlock(2);                                        
                     door2locktimer=millis();               
                                            }
                     else Serial.print("Invalid door number!");
                     break;
                            } 

                   case 'r': {                                                 // Remove a user
                    dumpUser(atoi(cmdString[1]));
                    deleteUser(atoi(cmdString[1]));
                    break; 
                             }              

                   case 'm': {                                                 // Add/change a user                   
                    dumpUser(atoi(cmdString[1]));
                    addUser(atoi(cmdString[1]), atol(cmdString[2]), atoi(cmdString[3]));
                    dumpUser(atoi(cmdString[1]));
                    break;
                             }
                             
                  case '?': {                                                  // Display help menu
                   Serial.println("Valid commands are:");
                   Serial.println("(d)ate, (s)show user, (m)odify user <num>  <usermask> <tagnumber>");
                   Serial.println("(a)ll user dump,(r)emove_user <num>,(o)open door <num>");
                   Serial.println("(u)nlock all doors,(l)lock all doors");
                   Serial.println("(1)disarm_alarm, (2)arm_alarm,(3)train_alarm ");
                   
                   break;
                            }

                   default:  
                    Serial.println("Invalid command. Press '?' for help.");
                    break;
                                     }  
                   
  }                                    // End of 'if' statement for Serial.available
 }                                     // End of 'if' for string finished
}                                      // End of function 
