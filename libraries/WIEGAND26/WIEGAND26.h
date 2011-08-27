// Wiegand26 library - Initially adapted by arclight@gmail.com from Mike Cook's Crazy People
// http://www.thebox.myzen.co.uk/Hardware/Crazy_People.html
//
// @author Mike Cook
// @author arclight@gmail
// @author Scott Bailey
// @TODO Select a license.

#ifndef	_WIEGAND26_H_ 
#define	_WIEGAND26_H_ 

#include <stdint.h>

/// WIEGAND26 Interface class
///
/// @todo fix this example for doxygen parsing 
/// @example
/// WIEGAND26 door0;
/// WIEGAND26 door1;
///
/// void setup()
/// {
///    door0.attach(2,3);
///    door1.attach(4,5);
/// }
///
/// void loop()
/// {
///    uint32_t memberID;
///    memberID = door0.getID();
///    if( memberID )
///       // ... do something ...
///    memberID = door1.getID();
///    if( memberID )
///       // ... do something ...
/// }
/// @endblock
class WIEGAND26
{
   enum
   {
      QUEUE_SIZE=5,
      ID_SIZE=26,
      READ_TIMEOUT=100,
      ID_TIMEOUT=500,
      
   };
public:
   /// constructor
   WIEGAND26();
   /// destructor
   ///  non-virtual!
   ~WIEGAND26();

   /// connect pins to the Wiegand Reader, initialize variables, and start reading!
   /// @see detach()
   /// @note No checking is done to ensure another Wiegand26 class doesn't have these pins...
   /// @param p0  Pin0 -- when this pin toggles, a zero is shifted into the id being read
   /// @param p1  Pin1 -- when this pin toggles, a one is shifted into the id being read
   void attach( uint8_t p0, uint8_t p1);
   /// detach the reader
   /// @see attach()
   void detach();
   /// get card id
   ///
   /// @note Card IDs are not queued up, instead a single card ID is stored for up to ID_TIMEOUT ms.  If a new card is swiped
   /// withing ID_TIMEOUT ms, that ID is dropped.  After ID_TIMEOUT ms, the stored ID is replaced by a fresh one.  A stale ID is
   /// never returned to the caller.
   ///
   /// @return non zero indicates a valid card id less than ID_TIMEOUT ms old.
   uint32_t getID();

   //private:
   /// function to manage a line getting toggled, hand to ISR
   /// @calls toggle() w/ arg of 0
   void toggledLineZero();
   /// function to manage a line getting toogeld, hand to ISR
   /// @calls toggle() w/ arg of 1
   void toggledLineOne();
   /// Single point to maintain for toggle lines
   void shiftIn(uint32_t high);
   /// reset the read related values
   void readReset() { readCount_=0; readValue_=0; readTime_=0; }
   /// reset the id related variables
   void idReset() { id_=0; idTime_=0; }

private:
   uint8_t p0_;  ///< Zero pin
   uint8_t p1_;  ///< One pin

   uint32_t id_;  ///< stored id, will get over written
   unsigned long idTime_;  ///< when the id was stored, will get overwritten

   unsigned readCount_;   ///< number of bits read so far
   uint32_t readValue_;   ///< storage for the value being read
   unsigned long readTime_;  ///< when the data was read
};

#endif
