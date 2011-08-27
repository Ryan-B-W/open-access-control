#include <WProgram.h>
#include <Wiegand26.h>
#include <PCATTACH.h>

//--- file statics -----------------------------------------------------------------------------------------------------

static void initPin(uint8_t pin)
{
   pinMode(pin, OUTPUT);
   digitalWrite(pin, HIGH); // enable internal pull up causing a one
   digitalWrite(pin, LOW); // disable internal pull up causing zero and thus an interrupt

   pinMode(pin, INPUT);
   digitalWrite(pin, HIGH); // enable internal pull up
}

//typedef (void(Wiegand26::*)()) wiegfunc;

Wiegand26* cs[10]={0,0,0,0,0};

void func00() { cs[0]->do0(); }
void func01() { cs[0]->do1(); }
void func10() { cs[0]->do0(); }
void func11() { cs[0]->do1(); }
... a bunch of times...?

static g_attach(Wiegand26* who, uint8_t p0, uint8_t p1)
{


}


static g_detatch(Wiegand26* who, uint8_t p0, uint8_t p1)
{


}


//--- constructors/destructor ------------------------------------------------------------------------------------------

Wiegand26::Wiegand26()
   : p0_(0)
   , p1_(0)
{
}

 
Wiegand26::~Wiegand26()
{
   if( p0_ )
      detach();
}

//--- alphabetic -------------------------------------------------------------------------------------------------------



void Wiegand26::attach( uint8_t p0, uint8_t p1)
{
   // sanity check
   if( p0_ )
      detatch();

   void(*func)() = reinterpret_cast<void(*)()>(&Wiegand26::toggledLineOne);

   // setup the interupts
   pcattach.PCattachInterrupt(p0_, (void(*)())&toggledLineZero, CHANGE);
   pcattach.PCattachInterrupt(p1_, &Wiegand26::toggledLineOne, CHANGE);

   // init the pins
   initPin(p0_);
   initPin(p1_);

   // sleep a bit and then clear the system state
   delay(10);
   idReset();
   readReset();
}


void Wiegand26::detach()
{
   pcattach.PCdetachInterrupt(p0_);
   pcattach.PCdetachInterrupt(p1_);
   readReset();
   idReset();
   p0_ = 0;
   p1_ = 0;
}


uint32_t Wiegand26::getID()
{
   uint32_t rv; // return value
   // don't provide stale IDs.
   unsigned long now = millis();
   if( (now - idTime_) > ID_TIMEOUT)
      rv = 0;
   else
      rv = id_;
   idReset();
   return rv;
}


void Wiegand26::shiftIn(uint32_t val)
{
   // timeout check between now and the last bit
   unsigned long now = millis();
   if( (now - readTime_) > READ_TIMEOUT)
      readReset();
   readTime_ = now;
   // shift up and shift the bit in
   readValue_ <<= 1;
   readValue_ |= val;
   ++readCount_;
   // if its a whole ID, then store it
   if( readCount_ == ID_SIZE )
   {
      // can't overwrite an existing value to quickly, so only overwrite a stale one:
      if( (readTime_ - idTime_) > ID_TIMEOUT)
      {
         id_ = readValue_;
         idTime_ = readTime_;
      }
      readReset();  // and clear out the read!
   }
}

 
void Wiegand26::toggledLineZero()
{
   // this logic check for the trailing edge, and if found shifts in the bit via a call
   if(!digitalRead(p0_))
      shiftIn(0);
}

 
void Wiegand26::toggledLineOne()
{
   // this logic check for the trailing edge, and if found shifts in the bit via a call
   if(!digitalRead(p1_))
      shiftIn(1);
}
