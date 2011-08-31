// PinCatcher - A pin change interrupt catcher.
// Copyright (C) 2011  Scott Bailey.  All rights reserved.
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.


#include "PinCatcher_impl.h"
#include "PinCatcher.h"
#include <pins_arduino.h>
#include <avr/io.h>
#include <string.h>

#include <WProgram.h>

//--- cosntructors/destructor ------------------------------------------------------------------------------------------

PinCatcher_impl::PinCatcher_impl()
   : pins0_( *portInputRegister(4) )
   , pins1_( *portInputRegister(2) )
   , pins2_( *portInputRegister(3) )
   , last0_( pins0_ )
   , last1_( pins1_ )
   , last2_( pins2_ )
   , mask0_(0)
   , mask1_(0)
   , mask2_(0)
{
   // need to clear the who slots.
   memset(who_, 0, (sizeof(PinCatcher*)*8) );
}


PinCatcher_impl::~PinCatcher_impl()
{
   PCICR = 0;
   PCMSK0 = 0;
   PCMSK1 = 0;
   PCMSK2 = 0;
}

//--- alphabetic -------------------------------------------------------------------------------------------------------

void PinCatcher_impl::attachPin(unsigned pin, PinCatcher* who)
{
   who_[pin]=who;
   if( pin < 8 )
   {
      uint8_t mask = (1 << pin);
      mask0_ |= mask;
      PCMSK2 |= mask0_;
      PCICR |= 4;
   }
   else if( pin < 14 )
   {
      uint8_t mask = (1 << (pin-8));
      mask1_ |= mask;
      PCMSK0 |= mask1_;
      PCICR |= 1;
   }
   else
   {
      uint8_t mask = (1 << (pin-14));
      mask2_ |= mask;
      PCMSK1 |= mask2_;
      PCICR |= 2;
   }
}


void PinCatcher_impl::detachPin(unsigned pin)
{
   if( pin < 8 )
   {
      uint8_t mask = 0xFF ^ (1 << pin);
      mask0_ &= mask;
      PCMSK2 = mask0_;
      if( !mask0_ )
         PCICR &= 3;
   }
   else if( pin < 14 )
   {
      uint8_t mask = 0xFF ^ (1 << (pin-8));
      mask1_ |= mask;
      PCMSK0 = mask1_;
      if( !mask1_ )
         PCICR &= 6;
   }
   else
   {
      uint8_t mask = 0xFF ^ (1 << (pin-14));
      mask2_ &= mask;
      PCMSK1 = mask2_;
      if( !mask2_ )
         PCICR &= 5;
   }
   who_[pin]=0;
}


void PinCatcher_impl::handlePins0()
{
   uint8_t curr = pins0_;
   uint8_t changed = mask0_ & (curr ^ last0_);  // and the mask with the XOR values
   last0_ = curr;
   
   uint8_t count=0;  // this is the pin number we look at inside the loop (i.e. the first pin in the bank.)
   // as long as there is a changed pin left, keep looping and looking at the LSB of changed.
   while( changed )
   {
      // if the bit changed, let the listener class know.  Also mask off the current state of the pin, high or low.
      if( changed & 0x01 )
         who_[count]->handle(count, (curr & 0x01));
      // shift off the lsb of the changed and current states
      changed >>= 1;
      curr >>= 1;
      // increment the count so we know what pin to tell the listeners!
      ++count;
   }
}
   

void PinCatcher_impl::handlePins1()
{
   // see handlePins0_ for comments
   uint8_t curr = pins1_;
   uint8_t changed = mask1_ & (curr ^ last1_);
   last1_ = curr;
   
   uint8_t count=8;
   while( changed )
   {
      if( changed & 0x01 )
         who_[count]->handle(count, (curr & 0x01));
      changed >>= 1;
      curr >>= 1;
      ++count;
   }
}

void PinCatcher_impl::handlePins2()
{
   // see handlePins0_ for comments
   uint8_t curr = pins2_;
   uint8_t changed = mask2_ & (curr ^ last2_);
   last2_ = curr;
   
   uint8_t count=14;
   while( changed )
   {
      if( changed & 0x01 )
         who_[count]->handle(count, (curr & 0x01));
      changed >>= 1;
      curr >>= 1;
      ++count;
   }
}




//-------------------------------------------------------------------------------------------------------------------------
//--- implementation details ----------------------------------------------------------------------------------------------
//-------------------------------------------------------------------------------------------------------------------------

//-------------------------------------------------------------------------------------------------------------------------
// this is THE pin catcher implementation
PinCatcher_impl pc_i;

//-------------------------------------------------------------------------------------------------------------------------
// these are the Interrupt Service Routines (ISR).  They call the above class.
void handlePins0_isr()
{
   pc_i.handlePins0();
}

void handlePins1_isr()
{
   pc_i.handlePins1();
}

void handlePins2_isr()
{
   pc_i.handlePins2();
}

//-------------------------------------------------------------------------------------------------------------------------
// these make the system call our ISRs.  We might be able to optimzes this.
ISR(PCINT0_vect)
{
   handlePins1_isr(); 
}
   
ISR(PCINT1_vect)
{
   handlePins2_isr();
}

ISR(PCINT2_vect)
{
   handlePins0_isr();
}


//-------------------------------------------------------------------------------------------------------------------------
// Sanity checks for chipset

#if defined (__AVR_ATmega128__) || defined (__AVR_ATmega328P__) || defined (__AVR_ATmega328__)
  // success!  These chips are supported
#elif defined(__AVR_ATmega1280__) || defined(__AVR_ATmega2560__)
# error "Your Arduino's chipset isn't supported by PinCatcher!  Please consider writing the fix!"
#else
# error "Your Arduino's chipset isn't supported by PinCatcher!  But just to make sure, double check the code!  I'm likely wrong."
#endif
