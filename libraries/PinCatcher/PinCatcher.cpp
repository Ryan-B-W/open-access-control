#include "PinCatcher_impl.h"
#include "PinCatcher.h"
//#include <avr/io.h>
#include <avr/interrupt.h>


//---------------------------------------------------------------------------------------------------------

// this is THE pin catcher implementation
PinCatcher_impl pc_i;

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

// these make the system call our ISRs.  We might be able to optimzes this.
ISR(PCINT0_vect)
{
   handlePins0_isr(); 
}
   
ISR(PCINT1_vect)
{
   handlePins1_isr();
}

ISR(PCINT2_vect)
{
   handlePins2_isr();
}


//--- constructors/destructor ------------------------------------------------------------------------------------------

PinCatcher::PinCatcher()
{
}


PinCatcher::~PinCatcher()
{
}

//--- alphabetic -------------------------------------------------------------------------------------------------------

void PinCatcher::attach(unsigned pin)
{
   if( pin < 20 )
      pc_i.attachPin(pin, this);
}

void PinCatcher::detach(unsigned pin)
{
   if( pin < 20 )
      pc_i.detachPin(pin);
}

