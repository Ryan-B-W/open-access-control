#include <WProgram.h>
#include <Wiegand26.h>

//--- file statics -----------------------------------------------------------------------------------------------------

static void initPin(uint8_t pin)
{
   pinMode(pin, OUTPUT);
   digitalWrite(pin, HIGH); // enable internal pull up causing a one
   digitalWrite(pin, LOW); // disable internal pull up causing zero and thus an interrupt

   pinMode(pin, INPUT);
   digitalWrite(pin, HIGH); // enable internal pull up
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



void Wiegand26::attach( unsigned p0, unsigned p1)
{
   // sanity check
   if( p0_ )
      detach();

   p0_ = p0;
   p1_ = p1;

   parent::attach( p0_ );
   parent::attach( p1_ );

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
   parent::detach(p0_);
   parent::detach(p1_);
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


void Wiegand26::handle(unsigned pin, bool transition_high)
{
   if( transition_high )
      return;

   // low transitions generate the pulse.
   if( pin == p0_)
      shiftIn(0);
   else // assume pin == p1_
      shiftIn(1);
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
