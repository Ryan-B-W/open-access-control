/*
 * Open Source RFID Access Controller
 *
 * 10/5/2010 v1.17
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
 * Outputs go to an open-collector relay driver for magnetic door hardware.
 * Analog inputs are used for alarm sensor monitoring.  These should be
 * isolated as well, since many sensors use +12V. Note that resistors of
 * different values can be used on each zone to detect shorting of the sensor
 * or wiring.
 *
 * Version 1.00 of the hardware implements these features and uses the following pin 
 * assignments on a standard Arduino Duemilanova or Uno:
 *
 * Relay outpus on digital pins 6,7,8,9
 * DS1307 Real Time Clock (I2C):A4 (SDA), A5 (SCL)
 * Analog pins (for alarm):A0,A1,A2,A3 
 * Reader 1: pins 2,3
 * Reader 2: pins 4,5
 * Ethernet: pins 10,11,12,13 (Not connected to the board, reserved for the Ethernet shield)
 *
 */

/* Header files - stuff we're including
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


/* User List - Implemented as an array for testing or small installations.
*/

#define queeg      111111       // Name and badge number in HEX. We are not using checksums or site ID, just the whole
                                // output string from the reader.
#define arclight   0x14B949D    
#define kallahar   0x2B46B62
#define danozano   0x3909D3
#define flea       55555

long  superUserList[] = {arclight,danozano,kallahar,queeg,flea};  //User access table (Move to flash later)


#define DOORDELAY 2500                  // How long to open door lock once access is granted. (2500 = 2.5s)
#define SENSORTHRESHOLD 100             // Voltage level (0-1024) below which an alarm zone is considered open. 0..1024 == 0..5V

#define EEPROM_ALARM 0                  // EEPROM address to store alarm state between reboots (0..511)
#define EEPROM_ALARMARMED 1             // EEPROM address to store alarm armed state between reboots
#define EEPROM_ALARMZONES 20            // Starting address to store "normal" analog values for alarm zone sensor reads.
#define KEYPADTIMEOUT 5000              // Timeout for pin pad entry.

#define EEPROM_FIRSTUSER 24
#define EEPROM_LASTUSER 1024
#define NUMUSERS  ((EEPROM_LASTUSER - EEPROM_FIRSTUSER)/4)  //Define number of internal users (250 for UNO/Duemillanova)

#define DOORPIN1 relayPins[2]           // Define door 1 pin
#define DOORPIN2 relayPins[2]           // Define door 2 pin
#define ALARMSTROBEPIN relayPins[0]     // Define the reader LED pin
#define ALARMSIRENPIN relayPins[3]      // Define the alarm siren pin

byte reader1Pins[]={2,3};               // Reader 1 connected to pins 4,5
byte reader2Pins[]= {4,5};              // Reader2 connected to pins 6,7
//byte reader3Pins[]= {10,11};                // Reader3 connected to pins X,Y (Not implemented on v1.00 Access Control Board)

const byte analogsensorPins[] = {0,1,2,3};    // Alarm Sensors connected to other analog pins
const byte relayPins[]= {6,7,8,9};            // Relay output pins


#define numUsers (sizeof(superUserList)/sizeof(long))                  //User access array size (used in later loops/etc)
#define NUMDOORS (sizeof(doorPin)/sizeof(byte))
#define numAlarmPins (sizeof(analogsensorPins)/sizeof(byte))

//Other global variables

byte second, minute, hour, dayOfWeek, dayOfMonth, month, year;  // RTC clock variables

byte alarmStatus = EEPROM.read(EEPROM_ALARM);                   // Read the last alarm state as saved in eeprom.
byte alarmArmed = EEPROM.read(EEPROM_ALARMARMED);               // Alarm level variable (0..5, 0==OFF) 


// Enable up to 3 door access readers.
volatile long reader1 = 0;
volatile int  reader1Count = 0;
volatile long reader2 = 0;
volatile int  reader2Count = 0;
//volatile long reader3 = 0;                // Uncomment if using a third reader.
//volatile int  reader3Count = 0;

long keypadTime = 0;                                  // Timeout counter for  reader with key pad
long keypadValue=0;
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
     digitalWrite(relayPins[i], LOW);        //Sets the relay outputs to HIGH (relays off)
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
  chirpAlarm(8,ALARMSIRENPIN);                 //Chirp the alarm 8 times to show system ready.

//hardwareTest(100);      // IO Pin testing routing (use to check your inputs with hi/lo +(5-12V) sources)
                           // Also checks relay outputs.

}


void loop()                                     // Main branch, runs over and over again
{                         



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
  case 1: 
    {                                               // Alarm is armed, check sensor zones.
        if(alarmStatus==0){ 
          for(byte i=0; i<numAlarmPins; i++) {
            if(pollAlarm(i) ==1 ){
              alarmState(1);                        // If zone is tripped, immediately set AlarmStatus to 1 (alarm immediate).
                                                    // Only do this once if alarm activated.
                                 }
                                             }
    } 
       
      break;  
    } 

  case 4: 
    {                 //Door chime mode
      digitalWrite(DOORPIN1, HIGH);    //Leave door unlocked.
      if(pollAlarm(0) !=0) {
        chirpAlarm(10,ALARMSIRENPIN);
        break;  
      }
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


  if(reader1Count >= 26){                            //  tag presented to reader1
    logTagPresent(reader1,1);                        //  write log entry to serial port
                                                     //  CHECK TAG IN OUR LIST OF USERS. -255 = no match
    if(checkAccess(reader1) == 1) {                  //  if > 0 there is a match. checkAccess (reader1) is the userList () index 
      logAccessGranted(reader1, 1);                  //  log and unlock door 1

        if(alarmArmed !=0){ 
        alarmArmed =0;
        alarmState(0);                                       // Deactivate Alarm if armed. (Must do this _before_unlockin door.
      }                                            

      doorUnlock(DOORPIN1);                                           // Unlock the door.
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
 

  




  if(reader2Count >= 26){                           //  tag presented to reader2 (No keypad on this reader)
    logTagPresent(reader2,2);                       //  write log entry to serial port

    if(checkAccess(reader2) == 1) {                // If > 0 there is a match. 
      logAccessGranted(reader2, 2);                // Log and unlock door 2
      //  CHECK TAG IN OUR LIST OF USERS. -255 = no match
      if(alarmStatus !=0){
    
      }
      alarmState(0);                            //  Deactivate Alarm
      doorUnlock(DOORPIN2);                        // Unlock the door.



    }
    else if(checkAccess(reader2) !=1) {           //  no match, log entry written
      logAccessDenied(reader2,2);                 //  no tickee, no laundree
    }
  
    wiegand26.initReaderTwo();                   //  Reset for next tag scan

  }



}










 
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
      trainAlarm();                // Train the alarm sensors. Sets the default level (0..1024) for sensors in 
                                   // non-activated state to be in.
      chirpAlarm(4,ALARMSIRENPIN);
      break;
    }

  case 0x911: 
    {
      chirpAlarm(9,ALARMSIRENPIN);
      armAlarm(1);                   // Emergency
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

byte alarmState(byte alarmLevel) {        //Changes the alarm status


  logalarmState(alarmLevel); 
  switch (alarmLevel) {                              
  case 0: 
    {                                              // If alarmLevel == 0 turn off alarm.   
      digitalWrite(ALARMSIRENPIN, LOW);
      digitalWrite(ALARMSTROBEPIN, LOW);
      alarmStatus = alarmLevel;                    //Set global alarm level variable
      break;  
    }        
  case 1: 
    {                                              // If alarmLevel == 1 turn on strobe lights (SENSOR TRIPPED)
      digitalWrite(ALARMSTROBEPIN, HIGH);          //we would only activate a small LED if there was another output available. hint hint
      alarmStatus = alarmLevel;                    //Set global alarm level variable
      break;  
    }        
      
  case 2: 
    {
      digitalWrite(ALARMSIRENPIN, HIGH);          // If alarmLevel == 2 turn on strobe and siren (LOUD ALARM)
      digitalWrite(ALARMSTROBEPIN, HIGH);      
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
      digitalWrite(ALARMSIRENPIN, LOW);         //      Turn off siren
      digitalWrite(ALARMSTROBEPIN, LOW);        // and  Turn off strobe
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
  logalarmSensor(input);
  EEPROM.write(EEPROM_ALARM,input);  //Save the alarm sensor tripped to eeprom
    return 1;

  }
  else return 0;
}

void trainAlarm(){                       //Train the system about the default states of the alarm pins.
  int temp[5]={0,0,0,0,0};
  int avg;
  
  logtrainAlarm();
  for(int i=0; i<numAlarmPins; i++) {  //Save results to EEPROM

    for(int j=0; j<5;j++){
      temp[j]=analogRead(analogsensorPins[i]);
                         }
      avg=((temp[0]+temp[1]+temp[2]+temp[3]+temp[4])/20);
      Serial.print("Sensor ");Serial.print(i);Serial.print(" ");
      Serial.print("value:");Serial.println(avg);
      EEPROM.write((EEPROM_ALARMZONES+i),byte(avg)); 
      avg=0;
  }
  


}

void armAlarm(byte level){                       //Arm the alarm and set to level
  alarmArmed = level;
  logalarmArmed(level);
  if(level != EEPROM.read(EEPROM_ALARMARMED)){ 
    EEPROM.write(EEPROM_ALARMARMED,level); 
  }
}


/* Access System Functions - Modify these as needed for your application. 
 These function control lock/unlock and user lookup.
 */

int checkAccess(long input){       //Check to see if user is in the user list. If yes, return their index value.
  for(int i=0; i<=numUsers; i++){   
    if(input == superUserList[i]){
      return(1);
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
  digitalWrite(input, HIGH);
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" unlocked");
  delay(DOORDELAY);
  digitalWrite(input,LOW );
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" relocked");
}


void lockall() {                      //Lock down all doors. Can also be run periodically to safeguard system.

    digitalWrite(DOORPIN1, LOW);
    digitalWrite(DOORPIN2,LOW);
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

for(long counter=1; counter<=iterations; counter++) {                                  // Do this endlessly
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
 Serial.println("Relays 0..3 activated");
 delay(2000);
 digitalWrite(6,LOW);
 delay(25);
 digitalWrite(6,HIGH);
 digitalWrite(7,LOW);
 delay(25);
 digitalWrite(7,HIGH);
 digitalWrite(8,LOW);
 delay(25);
 digitalWrite(8,HIGH);
 delay(25);
 digitalWrite(9,LOW);
 delay(25);
 digitalWrite(9,HIGH);
 Serial.println("Relay speed test complete.");
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

void insertUser(int userNum, byte userMask, unsigned long tagnumber)    // Inserts a new users into the local database.
{                                                              // Users number 0..NUMUSERS
 int offset = (EEPROM_FIRSTUSER+(userNum*4)); //Find the offset to write this user to
byte EEPROM_buffer[] ={0,0,0,0};

  if((userNum <0) || (userNum > NUMUSERS)) {     //Do not write to invalid addresses.
   logDate(); 
   Serial.print("Invalid user insert attempted.");
                                           }
 else
  {
 

  
                           
     EEPROM_buffer[0] = tagnumber &  0xFF;
     EEPROM_buffer[1] = tagnumber >> 8;
     EEPROM_buffer[2] = tagnumber >> 16;
     EEPROM_buffer[3] = tagnumber >> 24;
     userMask = userMask & 64;                          //Access the last 6-bits of userMask

    for(int i=0; i<6; i++){
      bitWrite(EEPROM_buffer[2],(3+i),bitRead((userMask &64),i));  
                      }
                      
    for(int i=0; i<4; i++){
      EEPROM.write((offset+i), (EEPROM_buffer[i])); // Store the resulting value in 4 bytes of EEPROM.
                      }                          // Starting at offset.
          
               
                        
  logDate();
  Serial.print("User ");
  Serial.print(userNum);
  Serial.println("updated.");
  
   }
}


