#ifndef PINCATCHER_H
#define PINCATCHER_H

class PinCatcher
{
public:
   PinCatcher();
   virtual ~PinCatcher();

   virtual void handle(unsigned pin, bool transition_high)=0;
protected:
   virtual void attach(unsigned pin);
   virtual void detach(unsigned pin);
};



#endif
