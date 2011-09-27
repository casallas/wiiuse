/*
 *	wiiuse
 *
 *	Written By:
 *		Michael Laforest	< para >
 *		Email: < thepara (--AT--) g m a i l [--DOT--] com >
 *
 *	Copyright 2006-2007
 *
 *	This file is part of wiiuse.
 *
 *	This program is free software; you can redistribute it and/or modify
 *	it under the terms of the GNU General Public License as published by
 *	the Free Software Foundation; either version 3 of the License, or
 *	(at your option) any later version.
 *
 *	This program is distributed in the hope that it will be useful,
 *	but WITHOUT ANY WARRANTY; without even the implied warranty of
 *	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *	GNU General Public License for more details.
 *
 *	You should have received a copy of the GNU General Public License
 *	along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 *	$Header$
 *
 */

/**
 *	@file
 *	@brief Handles device I/O for Mac OS X.
 */

#ifdef __APPLE__

#include "io.h"

#include <stdlib.h>
#include <unistd.h>

#define BLUETOOTH_VERSION_USE_CURRENT
#import <IOBluetooth/IOBluetooth.h>

#define MAX_WIIMOTES 4
wiimote * g_wiimotes[MAX_WIIMOTES] = {NULL, NULL, NULL, NULL};

@interface SearchBT: NSObject {
@public
	unsigned int maxDevices;
}
@end

@implementation SearchBT
- (void) deviceInquiryComplete: (IOBluetoothDeviceInquiry *) sender
	error: (IOReturn) error
	aborted: (BOOL) aborted
{
	CFRunLoopStop(CFRunLoopGetCurrent());
}

- (void) deviceInquiryDeviceFound: (IOBluetoothDeviceInquiry *) sender
	device: (IOBluetoothDevice *) device
{
	WIIUSE_INFO("Discovered bluetooth device at %s: %s",
		[[device getAddressString] UTF8String],
		[[device getName] UTF8String]);

	if ([[sender foundDevices] count] == maxDevices)
		[sender stop];
}
@end

@interface ConnectBT: NSObject {}
@end

@implementation ConnectBT
- (void) l2capChannelData: (IOBluetoothL2CAPChannel *) l2capChannel
	data: (unsigned char *) data
	length: (NSUInteger) length
{
	IOBluetoothDevice *device = [l2capChannel getDevice];
	wiimote *wm = NULL;
	int i;

	for (i = 0; i < MAX_WIIMOTES; i++) {
		if (g_wiimotes[i] == NULL)
			continue;
		if ([device isEqual: g_wiimotes[i]->btd] == TRUE)
			wm = g_wiimotes[i];
	}

	if (wm == NULL) {
		WIIUSE_WARNING("Received packet for unknown wiimote");
		return;
	}

	if (length > MAX_PAYLOAD) {
		WIIUSE_WARNING("Dropping packet for wiimote %i, too large",
				wm->unid);
		return;
	}

	if (wm->inputlen != 0) {
		WIIUSE_WARNING("Dropping packet for wiimote %i, queue full",
				wm->unid);
		return;
	}

	memcpy(wm->input, data, length);
	wm->inputlen = length;

	//Stop the thread loop since we are already doing polling
	CFRunLoopStop(CFRunLoopGetCurrent());
	
#ifndef __LP64__
	//This keeps the screen saver from activating, but apparently it's not available in 64 bits
	(void)UpdateSystemActivity(UsrActivity);
#endif//TODO look for LP64 equivalent
	
}

- (void) l2capChannelClosed: (IOBluetoothL2CAPChannel *) l2capChannel
{
	IOBluetoothDevice *device = [l2capChannel getDevice];
	wiimote *wm = NULL;

	int i;

	//Look for the corresponding wm
	for (i = 0; i < MAX_WIIMOTES; i++) {
		if (g_wiimotes[i] == NULL)
			continue;
		if ([device isEqual: g_wiimotes[i]->btd] == TRUE)
			wm = g_wiimotes[i];
	}

	if (wm == NULL) {
		WIIUSE_WARNING("Channel for unknown wiimote was closed");
		return;
	}
	else{
		//TODO Not sure if this should disconnect the wiimote or just set channels to nil
		//wiiuse_disconnect(wm);

		if (l2capChannel == wm->cchan)
		{
			wm->cchan = nil;
			WIIUSE_WARNING("Lost control channel to wiimote %i", wm->unid);
		}
		if (l2capChannel == wm->ichan)
		{
			wm->ichan = nil;
			WIIUSE_WARNING("Lost input channel to wiimote %i", wm->unid);
		}
	}
	
}
@end

static int wiiuse_connect_single(struct wiimote_t* wm, char* address);

/**
 *	@brief Find a wiimote or wiimotes.
 *
 *	@param wm			An array of wiimote_t structures.
 *	@param max_wiimotes	The number of wiimote structures in \a wm.
 *	@param timeout		The number of seconds before the search times out.
 *
 *	@return The number of wiimotes found.
 *
 *	@see wiimote_connect()
 *
 *	This function will only look for wiimote devices.						\n
 *	When a device is found the address in the structures will be set.		\n
 *	You can then call wiimote_connect() to connect to the found				\n
 *	devices.
 */
int wiiuse_find(struct wiimote_t** wm, int max_wiimotes, int timeout) {
	IOBluetoothHostController *bth;
	IOBluetoothDeviceInquiry *bti;
	SearchBT *sbt;
	NSEnumerator *en;
	int i;
	int found_devices = 0, found_wiimotes = 0;

	// Count the number of already found wiimotes
	for (i = 0; i < MAX_WIIMOTES; ++i)
		if (wm[i] && wm[i]->btd)//check if we've already initialized the bluetooth device
			found_wiimotes++;

	bth = [[IOBluetoothHostController alloc] init];
	if ([bth addressAsString] == nil) {
		WIIUSE_ERROR("No bluetooth host controller");
		[bth release];
		return found_wiimotes;
	}

	sbt = [[SearchBT alloc] init];
	sbt->maxDevices = max_wiimotes - found_wiimotes;
	bti = [[IOBluetoothDeviceInquiry alloc] init];
	[bti setDelegate: sbt];
	[bti setInquiryLength: 5];
	[bti setSearchCriteria: kBluetoothServiceClassMajorAny
		majorDeviceClass: kBluetoothDeviceClassMajorPeripheral
		minorDeviceClass: kBluetoothDeviceClassMinorPeripheral2Joystick
		];
	[bti setUpdateNewDeviceNames: NO];

	if ([bti start] == kIOReturnSuccess)
		[bti retain];
	else
		WIIUSE_ERROR("Unable to do bluetooth discovery");

	//Start running the thread loop, this way the bluetooth device inquiry will start, reporting to the SearchBT delegate
	CFRunLoopRun();

	[bti stop];
	found_devices = [[bti foundDevices] count];

	WIIUSE_INFO("Found %i bluetooth device%c", found_devices,
		found_devices == 1 ? '\0' : 's');

	en = [[bti foundDevices] objectEnumerator];
	
	for (i=0; (i < found_devices) && (found_wiimotes < max_wiimotes); ++i) {
			/* found a device */
			wm[found_wiimotes]->btd = [en nextObject];

			WIIUSE_INFO("Found wiimote (%s) [id %i].",
				[[wm[found_wiimotes]->btd getAddressString] UTF8String],
				wm[found_wiimotes]->unid);

			WIIMOTE_ENABLE_STATE(wm[found_wiimotes], WIIMOTE_STATE_DEV_FOUND);
			++found_wiimotes;
	}
	[bth release];
	[bti release];
	[sbt release];

	return found_wiimotes;
}


/**
 *	@brief Connect to a wiimote or wiimotes once an address is known.
 *
 *	@param wm			An array of wiimote_t structures.
 *	@param wiimotes		The number of wiimote structures in \a wm.
 *
 *	@return The number of wiimotes that successfully connected.
 *
 *	@see wiiuse_find()
 *	@see wiiuse_connect_single()
 *	@see wiiuse_disconnect()
 *
 *	Connect to a number of wiimotes when the address is already set
 *	in the wiimote_t structures.  These addresses are normally set
 *	by the wiiuse_find() function, but can also be set manually.
 */
int wiiuse_connect(struct wiimote_t** wm, int wiimotes) {
	int connected = 0;
	int i = 0;

	for (; i < wiimotes; ++i) {
		if (!WIIMOTE_IS_SET(wm[i], WIIMOTE_STATE_DEV_FOUND))
			/* if the device address is not set, skip it */
			continue;

		if (wiiuse_connect_single(wm[i], NULL))
			++connected;
	}

	return connected;
}


/**
 *	@brief Connect to a wiimote with a known address.
 *
 *	@param wm		Pointer to a wiimote_t structure.
 *	@param address	The address of the device to connect to.
 *					If NULL, use the address in the struct set by wiiuse_find().
 *
 *	@return 1 on success, 0 on failure
 */
static int wiiuse_connect_single(struct wiimote_t* wm, char* address) {

	if (!wm || WIIMOTE_IS_CONNECTED(wm))
		return 0;

	int i;
	ConnectBT *cbt = [[ConnectBT alloc] init];
	[wm->btd openL2CAPChannelSync: &wm->cchan
		withPSM: kBluetoothL2CAPPSMHIDControl delegate: cbt];
	
	[wm->btd openL2CAPChannelSync: &wm->ichan
		withPSM: kBluetoothL2CAPPSMHIDInterrupt delegate: cbt];
	
	if (wm->cchan == nil || wm->ichan == nil) {
		WIIUSE_ERROR("Unable to open L2CAP channels "
			"for wiimote %i", wm->unid);
		[cbt release];
		return 0;
	}

	for (i = 0; i < MAX_WIIMOTES; i++) {
		if (g_wiimotes[i] == NULL) {
			g_wiimotes[i] = wm;
			break;
		}
	}

	WIIUSE_INFO("Connected to wiimote [id %i].", wm->unid);

	/* do the handshake */
	WIIMOTE_ENABLE_STATE(wm, WIIMOTE_STATE_CONNECTED);
	wiiuse_handshake(wm, NULL, 0);

	wiiuse_set_report_type(wm);

	[cbt release];
	return 1;
}


/**
 *	@brief Disconnect a wiimote.
 *
 *	@param wm		Pointer to a wiimote_t structure.
 *
 *	@see wiiuse_connect()
 *
 *	Note that this will not free the wiimote structure.
 */
void wiiuse_disconnect(struct wiimote_t* wm) {
	if (!wm || WIIMOTE_IS_CONNECTED(wm))
		return;
	int i;
	for (i = 0; i < MAX_WIIMOTES; i++) {
		if (wm == g_wiimotes[i])
			g_wiimotes[i] = NULL;
	}
	if (wm->cchan!=nil) {
		[wm->cchan setDelegate:nil];
		[wm->cchan closeChannel];
		wm->cchan = nil;
	}
	if (wm->ichan!=nil) {
		[wm->ichan setDelegate:nil];
		[wm->ichan closeChannel];
		wm->ichan = nil;
	}
	if (wm->btd!=nil) {
		[wm->btd closeConnection];
		[wm->btd release];
		wm->btd = nil;
	}

	wm->event = WIIUSE_NONE;

	WIIMOTE_DISABLE_STATE(wm, WIIMOTE_STATE_CONNECTED);
	WIIMOTE_DISABLE_STATE(wm, WIIMOTE_STATE_HANDSHAKE);
}


int wiiuse_io_read(struct wiimote_t* wm) {
	int bytes;
	
	if (!WIIMOTE_IS_CONNECTED(wm))
		return 0;
	
	//Run the thread loop for 1 second, so that ConnectBT may catch the read data events
	CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1, true);
	
	//There's no input return
	if (wm->inputlen == 0)
		return 0;
	
	//Copy the input to the event buffer
	bytes = wm->inputlen;
	memcpy(wm->event_buf, wm->input, bytes);
	wm->inputlen = 0;
	
	if (wm->event_buf[0] == '\0')
		bytes = 0;
	
	return bytes;
}


int wiiuse_io_write(struct wiimote_t* wm, byte* buf, int len) {
	IOReturn ret;

	if (!wm || !WIIMOTE_IS_CONNECTED(wm))
		return 0;

	ret = [wm->cchan writeAsync: buf length: len refcon: nil];

	if (ret == kIOReturnSuccess)
		return len;
	else
		return 0;
}



#endif /* ifdef __APPLE__ */
