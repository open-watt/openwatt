module urt.serial;





/+

##ifndef __SERIALPORT_H
##define __SERIALPORT_H

##include <stdio.h>
##include <stdlib.h>

##ifdef WIN32
##include <winsock2.h>
##include <commctrl.h>
##else
##include <unistd.h>
##include <sys/types.h>
##include <sys/stat.h>
##include <sys/socket.h>
##include <netinet/in.h>
##include <arpa/inet.h>
##include <fcntl.h>
##include <termio.h>
##include <strings.h>
##endif

##define ASCII_XON       0x11
##define ASCII_XOFF      0x13


class serialPort 
{
public:

   // BAUD RATE
   // 0="110", 1="300", 2="1200", 3="2400", 4="4800", 5="9600", 6="14400", 7="19200", 8="57600", 9="115200"
   int   baudRateIdx;
   
   // DATA BITS
   // 0="4", 1="5", 2="6", 3="7", 4="8"
   int   dataBitsIdx;
   
   // PARITY
   // 0="None", 1="Odd", 2="Even", 3="Mark", 4="Space"
   int   parityIdx;
   
   // STOP BITS
   // 0="1", 1="1.5", 2="2"
   int   stopBitsIdx;
   
   // FLOW CONTROL
   // 0="None", 1="Xon/Xoff", 2="Rts/Cts", 3="Dtr/Dsr"
   int   flowControlIdx;

   serialPort();
   virtual ~serialPort();
   int OpenCommConnection( char *port );
   int CloseCommConnection( void );
   int WriteCommBlock( char *lpByte , int dwBytesToWrite );
   int ReadCommBlock( char *lpszBlock, int nMaxLength );

private:

   int         td;
   int         serialConnected;
##ifdef WIN32
   HANDLE      idComDev;
   OVERLAPPED  osWrite;
   OVERLAPPED  osRead;
##endif

   int SetupCommConnection( void );

};

##endif

##include "serialPort.h"

//////////////////////////////////////////////////////////////////////
// Construction/Destruction
//////////////////////////////////////////////////////////////////////

serialPort::serialPort()
{
   baudRateIdx = 5;
   dataBitsIdx = 4;
   parityIdx = 0;
   stopBitsIdx = 0;
   flowControlIdx = 0;
   td = -1;
   serialConnected = 0;
}

serialPort::~serialPort()
{
}


//----------------------------------------------------------------------
int serialPort::OpenCommConnection( char *port )
{
##ifdef WIN32
   int     fRetVal;

   // create I/O event used for overlapped reads / writes
   osRead.Offset = 0;
   osRead.OffsetHigh = 0;
   osRead.hEvent = CreateEvent( NULL, 1,  0, NULL );
   osWrite.Offset = 0;
   osWrite.OffsetHigh = 0;
   osWrite.hEvent = CreateEvent( NULL, 1,  0, NULL );

   // open COMM device
   idComDev = CreateFile( port,
                          GENERIC_READ | GENERIC_WRITE,
                          0,
                          NULL,
                          OPEN_EXISTING,
                          FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH | FILE_FLAG_OVERLAPPED,
                          NULL );

   if ( idComDev == (HANDLE) -1 ) {
      return 0;
   }
   else {
      // get any early notifications
      SetCommMask( idComDev, EV_RXCHAR );

      // setup device buffers
      SetupComm( idComDev, 4096, 4096 );

      // purge any information in the buffer
      PurgeComm( idComDev, PURGE_TXABORT | PURGE_RXABORT |
                           PURGE_TXCLEAR | PURGE_RXCLEAR );
   }

   fRetVal = SetupCommConnection();

   if (fRetVal) {
      // assert DTR
      EscapeCommFunction( idComDev, SETDTR );
      // set connected flag to 1
      serialConnected = 1;
   }
   else {
      CloseHandle( idComDev );
   }
   return ( fRetVal );

##else
   // Open Serial Port
   if ( (td = open(port,O_RDWR)) == -1) {
      printf("ERROR - Unable to open serial port:  %s\n", port);
      exit(0);
   }

   SetupCommConnection();

   // Clear input and output queues
   tcflush(td,TCIOFLUSH);
   return (1);

##endif
}

//----------------------------------------------------------------------
int serialPort::SetupCommConnection( void )
{
##ifdef WIN32
   int            fRetVal;
   DCB            dcb;
   COMMTIMEOUTS   CommTimeOuts;
   DWORD          baudRateTable[] = {
                     CBR_110, CBR_300, CBR_1200, CBR_2400, CBR_4800, CBR_9600,
                     CBR_14400, CBR_19200, CBR_57600, CBR_115200
                  };


   // set up for overlapped I/O
   CommTimeOuts.ReadIntervalTimeout = 0xFFFFFFFF;
   CommTimeOuts.ReadTotalTimeoutMultiplier = 0;
   CommTimeOuts.ReadTotalTimeoutConstant = 1000;
   // CBR_9600 is approximately 1byte/ms. For our purposes, allow
   // double the expected time per character for a fudge factor.
   CommTimeOuts.WriteTotalTimeoutMultiplier = 10*CBR_9600/baudRateTable[ baudRateIdx ];
   CommTimeOuts.WriteTotalTimeoutConstant = 0;
   SetCommTimeouts( idComDev, &CommTimeOuts );

   dcb.DCBlength = sizeof( DCB );

   GetCommState( idComDev, &dcb );

   dcb.BaudRate = baudRateTable[ baudRateIdx ];
   dcb.ByteSize = dataBitsIdx + 4;
   dcb.Parity = parityIdx;
   dcb.StopBits = stopBitsIdx;

   // setup flow control

   switch ( flowControlIdx ) {
   case 1:     // Xon/Xoff control
      dcb.fInX = dcb.fOutX = 1;
      dcb.XonChar = ASCII_XON;
      dcb.XoffChar = ASCII_XOFF;
      dcb.XonLim = 200;
      dcb.XoffLim = 200;
      dcb.fRtsControl = RTS_CONTROL_ENABLE;
      dcb.fDtrControl = DTR_CONTROL_ENABLE;
      break;
   case 2:     // Rts/Cts control
      dcb.fInX = dcb.fOutX = 0;
      dcb.fRtsControl = RTS_CONTROL_HANDSHAKE;
      dcb.fDtrControl = DTR_CONTROL_ENABLE;
      break;
   case 3:     // Dtr/Dsr control
      dcb.fInX = dcb.fOutX = 0;
      dcb.fRtsControl = RTS_CONTROL_ENABLE;
      dcb.fDtrControl = DTR_CONTROL_HANDSHAKE;
      break;
   default:    // None
      dcb.fInX = dcb.fOutX = 0;
      dcb.fRtsControl = RTS_CONTROL_ENABLE;
      dcb.fDtrControl = DTR_CONTROL_ENABLE;
      break;
   }

   // other various settings

   dcb.fNull = 0;
   dcb.fBinary = 1;
   dcb.fParity = 1;

   fRetVal = SetCommState( idComDev, &dcb );

   return ( fRetVal );

##else
   struct termios  t;

   unsigned int   baudRateTable[] = {
                     B110, B300, B1200, B2400, B4800, B9600, 0, B19200, B57600, B115200
                  };
   unsigned int   charSizeTable[] = {
                     0, CS5, CS6, CS7, CS8
                  };

   // Setup Terminal Parameters
   tcgetattr(td,&t);
   t.c_iflag = 0;                      // input modes
   t.c_oflag = 0;                      // output modes
   t.c_lflag = 0;                      // local modes
   t.c_cc[VMIN] = 0;
   t.c_cc[VTIME] = 0;

   t.c_cflag = CREAD;                  // control modes

   t.c_cflag |= baudRateTable[ baudRateIdx ];

   if (parityIdx == 1)
      t.c_cflag |= PARENB | PARODD;
   else if (parityIdx == 2)
      t.c_cflag |= PARENB;

   t.c_cflag |= charSizeTable[ dataBitsIdx ];

   if (stopBitsIdx == 2)
      t.c_cflag |= CSTOPB;

   if (flowControlIdx < 2) t.c_cflag |= CLOCAL;

   cfsetispeed(&t, baudRateTable[baudRateIdx]);
   cfsetospeed(&t, baudRateTable[baudRateIdx]);
   tcsetattr(td,0,&t);

   return 1;

##endif
}

//----------------------------------------------------------------------
int serialPort::CloseCommConnection( void )
{
##ifdef WIN32
   // set connected flag to 0
   serialConnected = 0;

   // disable event notification and wait for thread to halt
   SetCommMask( idComDev, 0 );

   // drop DTR
   EscapeCommFunction( idComDev, CLRDTR );

   // purge any outstanding reads/writes and close device handle
   PurgeComm( idComDev, PURGE_TXABORT | PURGE_RXABORT |
                        PURGE_TXCLEAR | PURGE_RXCLEAR );

   CloseHandle( idComDev );
   CloseHandle( osRead.hEvent );
   CloseHandle( osWrite.hEvent );

   return 1;

##else
   if (td != -1) {
      close(td);
   }
   return 1;

##endif
}

//----------------------------------------------------------------------
int serialPort::WriteCommBlock( char *lpByte , int dwBytesToWrite )
{
##ifdef WIN32
   int         fWriteStat;
   DWORD       dwBytesWritten;
   DWORD       dwErrorFlags;
   DWORD       dwError;
   DWORD       dwBytesSent=0;
   COMSTAT     ComStat;

   if ( !serialConnected ) return 0;

   fWriteStat = WriteFile( idComDev,
                           (LPSTR)lpByte,
                           dwBytesToWrite,
                           &dwBytesWritten,
                           &osWrite );

   // Note that normally the code will not execute the following
   // because the driver caches write operations. Small I/O requests
   // (up to several thousand bytes) will normally be accepted
   // immediately and WriteFile will return 1 even though an
   // overlapped operation was specified

   if ( !fWriteStat ) {
      if ( GetLastError() == ERROR_IO_PENDING ) {

         // We should wait for the completion of the write operation
         // so we know if it worked or not

         // This is only one way to do this. It might be beneficial
         // to place the write operation in a separate thread
         // so that blocking on completion will not negatively
         // affect the responsiveness of the UI

         // If the write takes too long to complete, this
         // function will timeout according to the
         // CommTimeOuts.WriteTotalTimeoutMultiplier variable.
         // This code logs the timeout but does not retry
         // the write.

         while ( !GetOverlappedResult( idComDev, &osWrite, &dwBytesWritten, 1 ) )
         {
            dwError = GetLastError();
            if ( dwError == ERROR_IO_INCOMPLETE ) {
               // normal result if not finished
               dwBytesSent += dwBytesWritten;
               continue;
            }
            else {
               // an error occurred, try to recover
               ClearCommError( idComDev, &dwErrorFlags, &ComStat );
               break;
            }
         }
         dwBytesSent += dwBytesWritten;
      }
      else {
         // some other error occurred
         ClearCommError( idComDev, &dwErrorFlags, &ComStat );
         return 0;
      }
   }
   return 1;

##else
   int n;

   n = write(td, lpByte, dwBytesToWrite);
   if (n != dwBytesToWrite) return 0;
   return 1;

##endif
}

//----------------------------------------------------------------------
int serialPort::ReadCommBlock( char *lpszBlock, int nMaxLength )
{
##ifdef WIN32
   int         fReadStat;
   COMSTAT     ComStat;
   DWORD       dwErrorFlags;
   DWORD       dwLength;
   DWORD       dwError;

   if ( !serialConnected ) return 0;

   // only try to read number of bytes in queue
   ClearCommError( idComDev, &dwErrorFlags, &ComStat );
   dwLength = min( (DWORD) nMaxLength, ComStat.cbInQue );

   if (dwLength > 0) {

      fReadStat = ReadFile( idComDev,
                            (LPSTR)lpszBlock,
                            dwLength,
                            &dwLength,
                            &osRead );

      if ( !fReadStat ) {
         if ( GetLastError() == ERROR_IO_PENDING ) {

            // We have to wait for read to complete.
            // This function will timeout according to the
            // CommTimeOuts.ReadTotalTimeoutConstant variable
            // Every time it times out, check for port errors

            while ( !GetOverlappedResult( idComDev, &osRead, &dwLength, 1 ) )
            {
               dwError = GetLastError();
               if (dwError == ERROR_IO_INCOMPLETE) {
                  // normal result if not finished
                  continue;
               }
               else {
                  // an error occurred, try to recover
                  ClearCommError( idComDev, &dwErrorFlags, &ComStat );
                  break;
               }
            }
         }
         else {
            // some other error occurred
            dwLength = 0;
            ClearCommError( idComDev, &dwErrorFlags, &ComStat );
         }
      }
   }
   return ( dwLength );

##else
   int dwLength;

   dwLength = read( td, lpszBlock, nMaxLength );
   return ( dwLength );

##endif
}

//----------------------------------------------------------------------

+/
