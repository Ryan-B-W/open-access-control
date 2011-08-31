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
#include <avr/interrupt.h>


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

