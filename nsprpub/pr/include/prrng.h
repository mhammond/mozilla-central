/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* 
 * The contents of this file are subject to the Mozilla Public
 * License Version 1.1 (the "License"); you may not use this file
 * except in compliance with the License. You may obtain a copy of
 * the License at http://www.mozilla.org/MPL/
 * 
 * Software distributed under the License is distributed on an "AS
 * IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
 * implied. See the License for the specific language governing
 * rights and limitations under the License.
 * 
 * The Original Code is the Netscape Portable Runtime (NSPR).
 * 
 * The Initial Developer of the Original Code is Netscape
 * Communications Corporation.  Portions created by Netscape are 
 * Copyright (C) 1998-2000 Netscape Communications Corporation.  All
 * Rights Reserved.
 * 
 * Contributor(s):
 * 
 * Alternatively, the contents of this file may be used under the
 * terms of the GNU General Public License Version 2 or later (the
 * "GPL"), in which case the provisions of the GPL are applicable 
 * instead of those above.  If you wish to allow use of your 
 * version of this file only under the terms of the GPL and not to
 * allow others to use your version of this file under the MPL,
 * indicate your decision by deleting the provisions above and
 * replace them with the notice and other provisions required by
 * the GPL.  If you do not delete the provisions above, a recipient
 * may use your version of this file under either the MPL or the
 * GPL.
 */


/*
** prrng.h -- NSPR Random Number Generator
** 
**
** lth. 29-Oct-1999.
*/

#ifndef prrng_h___ 
#define prrng_h___

#include "prtypes.h"

PR_BEGIN_EXTERN_C

/*
** PR_GetRandomNoise() -- Get random noise from the host platform
**
** Description:
** PR_GetRandomNoise() provides, depending on platform, a random value.
** The length of the random value is dependent on platform and the
** platform's ability to provide a random value at that moment.
**
** The intent of PR_GetRandomNoise() is to provide a "seed" value for a
** another random number generator that may be suitable for
** cryptographic operations. This implies that the random value
** provided may not be, by itself, cryptographically secure. The value
** generated by PR_GetRandomNoise() is at best, extremely difficult to
** predict and is as non-deterministic as the underlying platfrom can
** provide.
**
** Inputs:
**   buf -- pointer to a caller supplied buffer to contain the
**          generated random number. buf must be at least as large as
**          is specified in the 'size' argument.
**
**   size -- the requested size of the generated random number
**
** Outputs:
**   a random number provided in 'buf'.
**
** Returns:
**   PRSize value equal to the size of the random number actually
**   generated, or zero. The generated size may be less than the size
**   requested. A return value of zero means that PR_GetRandomNoise() is
**   not implemented on this platform, or there is no available noise
**   available to be returned at the time of the call.
**
** Restrictions:
**   Calls to PR_GetRandomNoise() may use a lot of CPU on some platforms.
**   Some platforms may block for up to a few seconds while they
**   accumulate some noise. Busy machines generate lots of noise, but
**   care is advised when using PR_GetRandomNoise() frequently in your
**   application.
**
** History:
**   Parts of the model dependent implementation for PR_GetRandomNoise()
**   were taken in whole or part from code previously in Netscape's NSS
**   component.
**
*/
NSPR_API(PRSize) PR_GetRandomNoise( 
    void    *buf,
    PRSize  size
);

PR_END_EXTERN_C

#endif /* prrng_h___ */
/* end prrng.h */
