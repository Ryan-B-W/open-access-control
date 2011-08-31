//
//
//
//  Wire your Arduino UNO or equivalent using jumper wire between the following pins:
//  
//  D11 <--> D04
//  D12 <--> D10
//  D13 <--> A03   <--- Note the A!
//
//  Connect to your Arduino over the serial line at 57600
//
//  Use tab or enter to see the pin states
//
//  q,w,e -- high/low toggle pins 11,12,13 (respectively)
//  a,s,d -- set pins 11,12,13 (respectively) high
//  z,x,c -- set pins 11,12,13 (respectively) low



#include <PinCatcher.h>

class MyPinCatcher
   : public PinCatcher
{
   typedef PinCatcher parent;
public:
   MyPinCatcher()
   {
   }
   
   ~MyPinCatcher() {}

   void watch(unsigned pin)
   {
      attach(pin);
   }

   void ignore(unsigned pin)
   {
      detach(pin);
   }
   
   virtual void handle(unsigned pin, bool rising_edge_transition)
   {
      Serial.print("Changed: ");
      Serial.print(pin);
      Serial.print(" ");
      Serial.println(rising_edge_transition);
   }
};



MyPinCatcher p;


void setup()
{
   Serial.begin(57600);
   Serial.println("\n\nStarting PinCatcher test.\n");

   // setup the output pins
   pinMode(11,OUTPUT);
   pinMode(12,OUTPUT);
   pinMode(13,OUTPUT);// led

   // setup the input pins
   pinMode(4,INPUT);
   pinMode(10,INPUT);
   pinMode(17,INPUT);

   // setup watches for the input pins
   p.watch(4);
   p.watch(10);
   p.watch(17);
}



void loop()
{
   delay(100);

   int temp=Serial.read();
   switch(temp)
   {
      case 13:
      case '\t':
         Serial.print("Pins:\t");
         Serial.print(digitalRead(11));
         Serial.print(digitalRead(12));
         Serial.print(digitalRead(13));
         Serial.print(" --> ");
         Serial.print(digitalRead(4));
         Serial.print(digitalRead(10));
         Serial.println(digitalRead(17));
         break;
         
      case 'q':
         digitalWrite(11,!digitalRead(11));
         break;
      case 'a':
         digitalWrite(11,1);
         break;
      case 'z':
         digitalWrite(11,0);
         break;
         
      case 'w':
         digitalWrite(12,!digitalRead(12));
         break;
      case 's':
         digitalWrite(12,1);
         break;
      case 'x':
         digitalWrite(12,0);
         break;
         
      case 'e':
         digitalWrite(13,!digitalRead(13));
         break;
      case 'd':
         digitalWrite(13,1);
         break;
      case 'c':
         digitalWrite(13,0);
         break;
         
      default:
         ;
   }
}



