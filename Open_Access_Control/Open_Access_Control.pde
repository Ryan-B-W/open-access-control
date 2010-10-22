/*
 * Open Source RFID Access Controller
 *
 * 10/20/2010 v1.19
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
#include <PCATTACH.h>     // Pcint.h library, allows for >2 software interupts. 
                          // Interrupts are used for all reader pins.


/*  Ethernet logging variables. Change the mac and IP
 *  addresses as needed. 
 */

byte useEthernet=1;                       // Set to 0 if not using Arduino Ethernet Shield.
                                       // Also comment out the next 4 lines.        

   byte mac[] = { 0x00, 0xAD, 0xBE, 0xEF, 0x23, 0x23 };
   byte ip[] = { 192, 168, 2, 120 };                    // Local IP address for the Access Control system.
   byte server[] = { 192,168,2,127 };                   // My remote web server
   Client client(server, 80);                                 // Port to connect to (default http=80)




/*  Super User List - Hardcoded users that are not stored in flash and cannot be accidentally deleted.
 *  Store a tag number or a PIN code if using reader with keypad. PIN can be 7 digits or 6 digits 
 *  terminated with a '#' character (0xB on our readers).
 */

#define danozano   0x123456B     // Name and badge number in HEX. We are not using checksums or site ID, just the whole
#define arclight   0x1234567     // output string from the reader.
long  superUserList[] = {danozano, arclight};  // Super User table.
#define NUMSUPERUSERS (sizeof(superUserList)/sizeof(long))                  //User access array size (used in later loops/etc)

/*  Delay values - change these to customize your
 *  site requirements.
 *
 */

#define DOORDELAY 2500                  // How long to open door lock once access is granted. (2500 = 2.5s)
#define KEYPADTIMEOUT 5000              // Timeout for pin pad entry. Defines how many ms to wait for keypad
                                        // commands after a successful tag read.




#define EEPROM_ALARM 0                  // EEPROM address to store alarm state between reboots (0..511)
#define EEPROM_ALARMARMED 1             // EEPROM address to store alarm armed state between reboots
#define EEPROM_ALARMZONES 20            // EEPROM starting address to store "normal" analog values for alarm zone sensor reads.
                                        // 4 alarm zones total.
#define EEPROM_FIRSTUSER 24             // EEPROM starting address for user database.
#define EEPROM_LASTUSER 1024            // EEPROM ending address for user database.

#define NUMUSERS  ((EEPROM_LASTUSER - EEPROM_FIRSTUSER)/5)  //Define number of internal users (200 for UNO/Duemillanova)


#define DOORPIN1 relayPins[2]           // Define door 1 pin
#define DOORPIN2 relayPins[1]           // Define door 2 pin
#define ALARMSTROBEPIN relayPins[0]     // Define the Chirp or pre-alarm relay output pin.
#define ALARMSIRENPIN relayPins[3]      // Define the alarm siren pin.



/*  Pin assignments.  These variables are correct for the Open Access Control
 *  Hardware v1.00u2. May need changes if not using this shield.
 */

byte reader1Pins[]={2,3};               // Reader 1 connected to pins 4,5
byte reader2Pins[]= {4,5};              // Reader2 connected to pins 6,7
//byte reader3Pins[]= {10,11};          // Reader3 connected to pins X,Y (Not implemented on v1.00 Access Control Board)

const byte analogsensorPins[] = {0,1,2,3};    // Alarm Sensors connected to other analog pins. 
                                              // The analog pins are used to read the alarm zones.
#define numAlarmPins (sizeof(analogsensorPins)/sizeof(byte))


const byte relayPins[]= {6,7,8,9};            // Relay output pins


/*  Door lock variables. Keep track of time door was last opened and its expected status.
 *
 */

bool door1Locked=true;                        // Keeps track of whether the doors are supposed to be locked.
bool door2Locked=true;

long door1locktimer=0;
long door2locktimer=0;

#define NUMDOORS (sizeof(doorPin)/sizeof(byte))

/* Alarm variables
 *
 */
#define SENSORTHRESHOLD 50                                      // Analog sensor change that will trigger an alarm (0..255)
#define SIRENCYCLES 10                                          // How many 2-minute cycles to sound the siren for if activated.
byte alarmStatus = EEPROM.read(EEPROM_ALARM);                   // Read the last alarm state as saved in eeprom.
byte alarmArmed = EEPROM.read(EEPROM_ALARMARMED);               // Alarm level variable (0..5, 0==OFF) 
long chimeDelay=0;                                              // Timer to keep track of last door chime time
long sirenTimer=0;                                              // Timer to keep track of last siren turn-on.
byte sirenCycles=0;                                             // Number of iterations of siren cycle.


/* Real time clock variables. Used by the RTC functions.
 *
 */
byte second, minute, hour, dayOfWeek, dayOfMonth, month, year;  // RTC clock variables



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

    

  Wire.begin();                      // Start Wire library as I2C-Bus Master

  if(useEthernet==1){
  Ethernet.begin(mac, ip);           // Start the Ethernet client
                 }
                 
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
  chirpAlarm(1,ALARMSIRENPIN);                 //Chirp the alarm to show system ready.

  //hardwareTest(100);      // IO Pin testing routing (use to check your inputs with hi/lo +(5-12V) sources)
  // Also checks relay outputs.

  //insertUser(0, 64, 0x14B2164);
  //insertUser(199, 64, 0x14B949D); 
 // dumpUsers();


}
void loop()                                     // Main branch, runs over and over again
{                         


/* Check if doors are supposed to be locked and lock them 
 * if needed.
 */

  if(((millis() - door1locktimer) >= DOORDELAY) && door1locktimer !=0)
  { 
    if(door1Locked==true) 
    doorLock(DOORPIN1);
    door1locktimer=0;
  }

  if(((millis() - door2locktimer) >= DOORDELAY) && door2locktimer !=0)
  { 
    if(door2Locked==true) 
    doorLock(DOORPIN2); 
    door2locktimer=0;
  }   

/* Check if alarm siren is supposed to be on and turn on or 
 * off if number of cycles and timer are correct.
 */

  if(((millis() - sirenTimer) >= 120000))
  { 
      
     digitalWrite(ALARMSIRENPIN, LOW);   // Turn off siren between cycles.
     digitalWrite(ALARMSTROBEPIN, LOW);

     if(sirenCycles<SIRENCYCLES){                // Start another alarm cycle if needed.                  
       chirpAlarm(3,ALARMSIRENPIN);
       sirenCycles++;
       sirenTimer=millis();
       digitalWrite(ALARMSIRENPIN, HIGH);   // Turn the siren back on.
       digitalWrite(ALARMSTROBEPIN, HIGH);
                                 }
                                
  }


  /*
   * Check physical sensors with 
   * the logic below. Behavior is based on
   * the current alarmArmed value.
   * 0=disarmed 
   * 1=armed
   * 2=
   * 3=
   * 4=door chime only (Unlock DOOR1, Check zone 0/chirp alarm if active)
   *
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
      if(pollAlarm(0) !=0 && (millis() - chimeDelay >5000)) {
        chirpAlarm(3,ALARMSIRENPIN);
        chimeDelay=millis();
        Serial.print(logDate());
        Serial.println("Front door opened (Chime)");
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


  if(reader1Count >= 26){                                //  tag presented to reader1
    logTagPresent(reader1,1);                            //  write log entry to serial port
    //  CHECK TAG IN OUR LIST OF USERS. -255 = no match
    if((checkSuperuser(reader1)==1)||checkUser(reader1) >=0)
    {                                                    //  if > 0 there is a match. checkSuperuser (reader1) is the userList () index 
      logAccessGranted(reader1, 1);                      //  log and unlock door 1

        if(alarmArmed !=0){ 
        alarmArmed =0;
        alarmState(0);                                       // Deactivate Alarm if armed. (Must do this _before_unlocking door.
      }                                            

      doorUnlock(DOORPIN1);                                           // Unlock the door.
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
    else  {           // If no user match, log entry written
      logAccessDenied(reader1,1);                 // no tickee, no laundree
    }

    wiegand26.initReaderOne();

  }                      







  if(reader2Count >= 26){                           //  tag presented to reader2 (No keypad on this reader)
    logTagPresent(reader2,2);                       //  write log entry to serial port

     if((checkSuperuser(reader2)==1)||(checkUser(reader2) >0)) {                // If > 0 there is a match. 
      logAccessGranted(reader2, 2);                // Log and unlock door 2
 

      //  CHECK TAG IN OUR LIST OF USERS. -255 = no match

      if(alarmStatus !=0){  
         alarmState(0);                            //  Deactivate Alarm
                          }

     door2locktimer=millis();
      doorUnlock(DOORPIN2);                        // Unlock the door.
    }
    else                              {           //  no match, log entry written
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
      alarmStatus = alarmLevel;                    // Set global alarm level variable
      sirenCycles=0;                               // Reset siren counter.
      break;  
    }        
  case 1: 
    {                                              // If alarmLevel == 1 turn on strobe lights (SENSOR TRIPPED)
      digitalWrite(ALARMSTROBEPIN, HIGH);          // we would only activate a small LED if there was another output available. hint hint
      alarmStatus = alarmLevel;                    // Set global alarm level variable
      sirenTimer=millis();                         // Set the siren timer
      break;  
    }        

  case 2: 
    {
      digitalWrite(ALARMSIRENPIN, HIGH);          // If alarmLevel == 2 turn on strobe and siren (LOUD ALARM)
      digitalWrite(ALARMSTROBEPIN, HIGH);      
      sirenTimer=millis();                         // Set the siren timer
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
    {                                            // Exceptional cases kill alarm outputs
      digitalWrite(ALARMSIRENPIN, LOW);         //  Turn off siren
      digitalWrite(ALARMSTROBEPIN, LOW);        //  Turn off strobe
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
   // logalarmSensor(input);
   // EEPROM.write(EEPROM_ALARM,input);  //Save the alarm sensor tripped to eeprom
    return 1;

  }
  else return 0;
}

void trainAlarm(){                       //Train the system about the default states of the alarm pins.
  int temp[5]={
    0,0,0,0,0  };
  int avg;

  logtrainAlarm();
  for(int i=0; i<numAlarmPins; i++) {  //Save results to EEPROM

    for(int j=0; j<5;j++){
      temp[j]=analogRead(analogsensorPins[i]);
    }
    avg=((temp[0]+temp[1]+temp[2]+temp[3]+temp[4])/20);
    Serial.print("Sensor ");
    Serial.print(i);
    Serial.print(" ");
    Serial.print("value:");
    Serial.println(avg);
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

int checkSuperuser(long input){       //Check to see if user is in the user list. If yes, return their index value.
  for(int i=0; i<=NUMSUPERUSERS; i++){   
    if(input == superUserList[i]){
      Serial.print(logDate());
      Serial.print("Superuser");
      Serial.print(i,DEC);
      Serial.print(" found in table.");
      return(1);
    }
  }                   
  return -255;             //If no, return -255
}




void doorUnlock(int input) {          //Send an unlock signal to the door and flash the Door LED
  digitalWrite(input, HIGH);
  
  Serial.print(logDate());
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" unlocked");

}

void doorLock(int input) {          //Send an unlock signal to the door and flash the Door LED
  digitalWrite(input, LOW);

  Serial.print(logDate());
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" locked");
  digitalWrite(input,LOW );

}
void lockall() {                      //Lock down all doors. Can also be run periodically to safeguard system.

  digitalWrite(DOORPIN1, LOW);
  digitalWrite(DOORPIN2,LOW);
  Serial.print(logDate());
  Serial.print("All Doors ");
  Serial.println(" relocked");
}

/* Logging Functions - Modify these as needed for your application. 
 Logging may be serial to USB or via Ethernet 
 */

String logDate()                                                                        // Get the date from the RTC and log it.
{                                                                                       // Use to timestamp other logged events.

ds1307.getDateDs1307(&second, &minute, &hour, &dayOfWeek, &dayOfMonth, &month, &year);  // Get RTC data
    
String dateString = String( String(hour, DEC)+ ":" + String(minute, DEC) + ":"+        // Put together into a date string.
String(second, DEC) + "-" + String(month, DEC) + "/" + String(dayOfMonth, DEC)+
"/" + String(year, DEC));


 switch(dayOfWeek) {
    
   case 1:{ dateString += "MON";break;}
   case 2:{ dateString += "TUE";break;}
   case 3:{ dateString += "WED";break;}
   case 4:{ dateString += "THU";break;}
   case 5:{ dateString += "FRI";break;}
   case 6:{ dateString += "SAT";break;}
   case 7:{ dateString += "SUN";break;}

                    }
                    
dateString += " ";
Serial.print(dateString);
return(dateString);

}                    

void logReboot() {                                  // Log to serial.
  String log=logDate();
  log+="***System Booted.";

  Serial.println(log);

  if(useEthernet==1){                              //Log to Ethernet if enabled.
   logEthernet(log); 
                    }


}


void logTagPresent (long user, byte reader) {     //Log Tag Presented events
  String log=logDate();
  log+="Tag Present ";
  log+="Reader ";
  log+=String(reader,DEC);
  log+=" ";
  log+=String(user,HEX);
  Serial.println(log);
  logEthernet(log);


/*
  logDate();
  Serial.print("User ");
  Serial.print(user,HEX);
  Serial.print(" presented tag at reader ");
  Serial.println(reader,DEC);
*/

}

void logAccessGranted(long user, byte reader) {     //Log Access events
  Serial.print(logDate());
  Serial.print("User ");
  Serial.print(user,HEX);
  Serial.print(" granted access at reader ");
  Serial.println(reader,DEC);
}                                         

void logAccessDenied(long user, byte reader) {     //Log Access denied events
  Serial.print(logDate());
  Serial.print("User ");
  Serial.print(user,HEX);
  Serial.print(" denied access at reader ");
  Serial.println(reader,DEC);
}   

void logkeypadCommand(byte reader, long command){
  Serial.print(logDate());
  Serial.print("Command ");
  Serial.print(command,HEX);
  Serial.print(" entered at reader ");
  Serial.println(reader,DEC);
}  

void logtrainAlarm() {
  Serial.print(logDate());
  Serial.println("Alarm Training performed.");
}

void logalarmSensor(byte zone) {     //Log Alarm zone events
  Serial.print(logDate());
  Serial.print("Zone ");
  Serial.print(zone,DEC);
  Serial.println(" sensor activated");
}

void logunLock(long user, byte door) {        //Log unlock events
  Serial.print(logDate());
  Serial.print("User ");
  Serial.print(user,HEX);
  Serial.print(" unlocked door ");
  Serial.println(door,DEC);

}

void logalarmState(byte level) {        //Log unlock events
  Serial.print(logDate());
  Serial.print("**Alarm level changed to ");
  Serial.println(level,DEC);
}

void logalarmArmed(byte level) {        //Log unlock events
  Serial.print(logDate());
  Serial.print("**Alarm armed level changed to ");
  Serial.println(level,DEC);
}



/*  User database maintenance functions. Controls lookups,
 *  adds, deletes, etc from 200-user database stored in
 *  eeprom. Uses bytes 0..4 of record to store tag number, 
 *  then an optional 1-byte usermask.
 */

void clearUsers()    //Erases all users from EEPROM
{
  for(int i=EEPROM_FIRSTUSER; i<=EEPROM_LASTUSER; i++){
    EEPROM.write(i,0);  
    Serial.print(logDate());
    Serial.println("User database erased.");  
  }
}

void insertUser(int userNum, byte userMask, unsigned long tagNumber)    // Inserts a new users into the local database.
{                                                                       // Users number 0..NUMUSERS
  int offset = (EEPROM_FIRSTUSER+(userNum*5));                           // Find the offset to write this user to
  byte EEPROM_buffer[] ={
    0,0,0,0,0  };                                     // Buffer for creating the 4 byte values to write. Usermask is store in byte 5.

  Serial.print(logDate());

  if((userNum <0) || (userNum > NUMUSERS)) {                            // Do not write to invalid EEPROM addresses.

    Serial.print("Invalid user insert attempted.");
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
      // Starting at offset.

      // Serial.print("Byte: ");Serial.print(i);Serial.print(" ");Serial.print("Data: ");Serial.println(EEPROM_buffer[i],HEX);
      // Serial.print(" ");Serial.print("EEPROM ADDRESS: ");Serial.println(offset+i,DEC);

    }

    Serial.print("User ");
    Serial.print(tagNumber,HEX); 
    Serial.print(" with usermask ");
    Serial.print(userMask,DEC); 
    Serial.print(" added at position "); 
    Serial.println(userNum,DEC);

  }
}

void deleteUser(byte userNum)     // Deletes a user from the local database.
{                                                                       // Users number 0..NUMUSERS
  int offset = (EEPROM_FIRSTUSER+(userNum*5));                           // Find the offset to write this user to
  byte EEPROM_buffer[] ={
    0,0,0,0,0  };                                     // Buffer for creating the 4 byte values to write. Usermask is store in byte 5.

  Serial.print(logDate());

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

byte getUsermask(byte userNum)                         // Returns the 8-bit "Usermask" or attribute for a user.
{
return(EEPROM.read( (EEPROM_FIRSTUSER+(userNum*5)+4))); // Return byte 5 of the user record 
}


byte checkUser(unsigned long tagNumber)                                  // Check if a particular tag exists in the local database. Returns userMask if found.
{                                                                       // Users number 0..NUMUSERS
  // Find the first offset to check

  unsigned long EEPROM_buffer=0;                                         // Buffer for recreating tagNumber from the 4 stored bytes.

  Serial.print(logDate());
  Serial.print("Tag lookup started for:");
  Serial.println(tagNumber,HEX);

  for(int i=EEPROM_FIRSTUSER; i<=(EEPROM_LASTUSER-5); i=i+5){


    EEPROM_buffer=0;
    EEPROM_buffer=(EEPROM.read(i+3));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+2));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i+1));
    EEPROM_buffer= EEPROM_buffer<<8;
    EEPROM_buffer=(EEPROM_buffer ^ EEPROM.read(i));

    //Serial.print("UserNum:");Serial.print(((i-EEPROM_FIRSTUSER)/5),DEC);
    //Serial.print("TagNum:");Serial.print(EEPROM_buffer,HEX);
    //Serial.print("Usermask:");Serial.println(EEPROM.read(i+4));

    if((EEPROM_buffer == tagNumber)&& (EEPROM_buffer != (0xFFFFFFFF || 0x0) ) )    //Check if record matches tag and is not blank.
     {
      Serial.print(logDate());
      Serial.print("User located at position ");
      Serial.println(((i-EEPROM_FIRSTUSER)/5),DEC);
    //  return(EEPROM.read(i+4));  //Returns usermask

      return(((i-EEPROM_FIRSTUSER)/5),DEC); //Returns user number.
    }                             

  }
  Serial.println("User not found");
  return(-255);                        
}


void dumpUsers()                                                        // Displays a lsit of all users in internal DB
{                                                                       // Users number 0..NUMUSERS


  unsigned long EEPROM_buffer=0;                                         // Buffer for recreating tagNumber from the 4 stored bytes.

  Serial.print(logDate());
  Serial.println("User dump started.");

  Serial.print("UserNum:");
  Serial.print("\t");
  Serial.print("TagNum:");
  Serial.println("Usermask:");
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
    Serial.print(EEPROM_buffer,HEX);
    Serial.print("\t");
    Serial.println(EEPROM.read(i+4),DEC);

  }
}




/*  Ethernet logging functions. Customize the https
 *  strings and URL for your web server and/or script.
 *  
 *  
 */




void logEthernet(String logString) {    //Log the specified string to an off-site HTTP server


 
  Serial.print("\n");
  Serial.print("Ethernet connecting...");

  // if you get a connection, report back via serial:
  if (client.connect()) {
    Serial.print("connected...");
 
    // send the HTTP PUT request. 
    client.print("GET /scripts/access.php?");   // Send the log data to web server
    client.print(logString);client.print("\f");
    client.print("HTTP/1.1\n");                                                                     
    client.print("Content-Type: text/csv\n");
    client.println("Connection: close\n");                // Close connection.
    Serial.println("Data sent. Disconnecting.");  
                        }
                        
                        
  else {
        Serial.println(" no connect. Disconnecting.");
       }

        client.stop();  


}


void hardwareTest(unsigned int iterations)
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
    Serial.print(logDate());
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
