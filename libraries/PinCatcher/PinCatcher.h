#ifndef PINCATCHER_H
#define PINCATCHER_H

/// PinCatcher class
/// @example Wiegang26.h
/// @example Wiegang26.cpp
///
/// make sure your derived class' destructor is modified with the virtual keyword!
///
class PinCatcher
{
public:
   /// constructor
   PinCatcher();
   /// destructor
   virtual ~PinCatcher();
   /// override this function to handle the pin change
   /// @param pin  The pin that changed
   /// @param rising_edge_transition  true if this is a rising edge tranistion, false for falling.
   virtual void handle(unsigned pin, bool rising_edge_transition)=0;
protected:
   /// attach this PinCatcher so it captures the interrupt for a given pin
   /// @param pin  The pin to capture interrupts for
   virtual void attach(unsigned pin);
   /// detach the PinCatcher so interrupts for a given pin are ignored
   /// @param pin  The pin to ignore
   virtual void detach(unsigned pin);
};



#endif
