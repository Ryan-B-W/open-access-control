#ifndef PINCATCHER_H
#define PINCATCHER_H

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


/// PinCatcher class
/// @example Wiegang26.h
/// @example Wiegang26.cpp
///
/// make sure your derived class' destructor is modified with the virtual keyword!
///
class PinCatcher
{
   // the PinCatcher Implementation class services the various interupts and calls the individual PinCatchers.
   // It is friended to protect handle()
   friend class PinCatcher_impl;
public:
   /// constructor
   PinCatcher();
   /// destructor
   /*virtual*/ ~PinCatcher();
protected:
   /// override this function to handle the pin change
   /// @param pin  The pin that changed
   /// @param rising_edge_transition  true if this is a rising edge tranistion, false for falling.
   virtual void handle(unsigned pin, bool rising_edge_transition)=0;
   /// attach this PinCatcher so it captures the interrupt for a given pin
   /// @param pin  The pin to capture interrupts for
   virtual void attach(unsigned pin);
   /// detach the PinCatcher so interrupts for a given pin are ignored
   /// @param pin  The pin to ignore
   virtual void detach(unsigned pin);
};



#endif
