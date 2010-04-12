/* Open Access Control for Hacker Spaces
 * Created by 23B Shop Hacker Space
 * http://23bshop.blogger.com
 * by John Norman and Dan Lozano
 * Readme updated 4/12/2010
*/

Note: Unpack the libraries (WIEGAND26, DS1307, PCATTACH) into your arduino
libraries directory.  This is usually:

arduino/hardware/libraries/

-The hardware design uses assumes the following parameters:

The hardware design for the Open Access Control for Hacker Spaces uses the Arduino Duemilanova 
board with Atmega 328, and provides:

-Shield compatible with Arduino
-DS1307 Real-time clock with battery backup
-(2) Wiegand26 reader inputs (optoisolated)
-(4) Alarm zone monitor ports using Analog0..3 (optoisolated)
-(4) Relay outputs, rated to 10A/220VAC
-Spare pins 10..13 to enable Ethernet shield use
-Built in 12V unregulated, 5V regulated, 12V regulated supplies for alarm sensors, door hardware
-Built in UPS (smart charger in next design)
-Separate fuse protection for everything

The following pin assignments are assumed:

-Pins 2,3 for Reader 1
-Pins 4,5 for Reader 2
-Pins 5,6,7,8 for Relays
-Pins A0,A1,A2,A3 for alarm sensors
-Pins A4,A5 for SDA,SCL (I2C)
