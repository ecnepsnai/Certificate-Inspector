//
//  CKOCSPManager.m
//
//  LGPLv3
//
//  Copyright (c) 2018 Ian Spence
//  https://tlsinspector.com/github.html
//
//  This library is free software: you can redistribute it and/or modify
//  it under the terms of the GNU Lesser Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This library is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU Lesser Public License for more details.
//
//  You should have received a copy of the GNU Lesser Public License
//  along with this library.  If not, see <https://www.gnu.org/licenses/>.

#import "CertificateKit.h"
#import "CKOCSPManager.h"
#import "CKCurlCommon.h"
#import <openssl/x509.h>
#import <openssl/ocsp.h>
#import <openssl/err.h>
#import <curl/curl.h>

@interface CKOCSPManager () {
    dispatch_queue_t queue;
}

@property (strong, nonatomic) NSMutableData * responseDataBuffer;

@end

@implementation CKOCSPManager

static CKOCSPManager * _instance;

#define OCSP_ERROR_INVALID_RESPONSE -1
#define OCSP_ERROR_CURL_LIBRARY -2
#define OCSP_ERROR_HTTP_ERROR -3
#define OCSP_ERROR_DECODE_ERROR -4
#define OCSP_ERROR_REQUEST_ERROR -5

+ (CKOCSPManager *) sharedManager {
    if (_instance != nil) {
        return _instance;
    }

    return [CKOCSPManager new];
}

- (instancetype) init {
    if (_instance == nil) {
        _instance = [super init];
        queue = dispatch_queue_create("com.tlsinspector.OCSPManager", NULL);
    }
    return _instance;
}

- (void) queryCertificate:(CKCertificate *)certificate issuer:(CKCertificate *)issuer response:(CKOCSPResponse * __autoreleasing *)rtresponse error:(NSError **)rterror {
    NSURL * ocspURL = certificate.ocspURL;
    if (ocspURL == nil) {
        return;
    }
    
    OCSP_CERTID * certID = OCSP_cert_to_id(NULL, certificate.X509Certificate, issuer.X509Certificate);
    PDebug(@"Querying OCSP for certificate: '%@'", certificate.subject.commonNames);
    OCSP_REQUEST * request = [self generateOCSPRequestForCertificate:certID];
    
    unsigned char * request_data = NULL;
    int len = i2d_OCSP_REQUEST(request, &request_data);
    if (len == 0) {
        *rterror = [NSError errorWithDomain:@"CKOCSPManager" code:OCSP_ERROR_DECODE_ERROR userInfo:@{NSLocalizedDescriptionKey: @"Unable to create OCSP request"}];
        PError(@"Error getting ASN bytes from OCSP request object");
        return;
    }
    NSData * requestData = [[NSData alloc] initWithBytes:request_data length:len];
    
    OCSP_BASICRESP * resp;
    NSError * queryError;
    [self queryOCSPResponder:ocspURL withRequest:requestData resp:&resp error:&queryError];
    if (queryError != nil) {
        *rterror = queryError;
        return;
    }
    CKOCSPResponse * response = [CKOCSPResponse new];
    *rtresponse = response;
    
    if (queryError != nil) {
        if (queryError.code == OCSP_ERROR_REQUEST_ERROR) {
            response.status = CKOCSPResponseStatusUnknown;
            PDebug(@"OCSP request status: Unknown");
            return;
        }
        *rterror = queryError;
        return;
    }
    
    int status;
    int reason;
    ASN1_GENERALIZEDTIME * time;
    ASN1_GENERALIZEDTIME * thisUP;
    ASN1_GENERALIZEDTIME * nextUP;
    if (!OCSP_resp_find_status(resp, certID, &status, &reason, &time, &thisUP, &nextUP)) {
        *rterror = [NSError errorWithDomain:@"CKOCSPManager" code:OCSP_ERROR_INVALID_RESPONSE userInfo:@{NSLocalizedDescriptionKey: @"Invalid OCSP response."}];
        [self openSSLError];
        PError(@"Unable to from status in OCSP response");
        return;
    }
    
    switch (status) {
        case V_OCSP_CERTSTATUS_GOOD:
            response.status = CKOCSPResponseStatusOK;
            PDebug(@"OCSP certificate status GOOD");
            break;
        case V_OCSP_CERTSTATUS_UNKNOWN:
            response.status = CKOCSPResponseStatusUnknown;
            PDebug(@"OCSP certificate status UNKNOWN");
            break;
        case V_OCSP_CERTSTATUS_REVOKED:
            response.status = CKOCSPResponseStatusRevoked;
            PDebug(@"OCSP certificate status REVOKED");
            response.reason = reason;
            response.reasonString = [NSString stringWithUTF8String:OCSP_crl_reason_str(reason)];
            break;
    }
    
    [self.responseDataBuffer setLength:0];
    OCSP_REQUEST_free(request);
    OCSP_BASICRESP_free(resp);
}

- (OCSP_REQUEST *) generateOCSPRequestForCertificate:(OCSP_CERTID *)certid {
    OCSP_REQUEST * request = OCSP_REQUEST_new();
    OCSP_request_add0_id(request, certid);
    return request;
}

- (OCSP_RESPONSE *) decodeResponse:(NSData *)data {
    const unsigned char * bytes = [data bytes];
    OCSP_RESPONSE * response = d2i_OCSP_RESPONSE(NULL, &bytes, data.length);
    return response;
}

- (void) queryOCSPResponder:(NSURL *)responder withRequest:(NSData *)request resp:(OCSP_BASICRESP **)resp error:(NSError **)error {
    CURL * curl = [[CKCurlCommon sharedInstance] curlHandle];
    if (!curl) {
        *error = [NSError errorWithDomain:@"CKOCSPManager" code:OCSP_ERROR_CURL_LIBRARY userInfo:@{NSLocalizedDescriptionKey: @"Error initalizing CURL library"}];
        PError(@"Error initalizing the CURL library. This shouldn't happen!");
        return;
    }

    // Prepare curl verbose logging but only use it if in debugg level
    // We have to use an in-memory file since curl expects a file pointer for STDERR
    static char *buf;
    static size_t len;
    FILE * curlout = NULL;
    if (@available(iOS 11, *)) {
        if (CKLogging.sharedInstance.level == CKLoggingLevelDebug) {
            curlout = open_memstream(&buf, &len);
            curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
            curl_easy_setopt(curl, CURLOPT_STDERR, stderr);
        }
    }

    self.responseDataBuffer = [NSMutableData new];
    curl_easy_setopt(curl, CURLOPT_URL, responder.absoluteString.UTF8String);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, ocsp_write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, self.responseDataBuffer);
    
    struct curl_slist *headers = NULL;
    headers = curl_slist_append(headers, "Content-Type: application/ocsp-request");
    headers = curl_slist_append(headers, "Accept: application/ocsp-response");
    
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 5L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, request.bytes);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, request.length);
    
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS, CURLPROTO_HTTP);
    curl_easy_setopt(curl, CURLOPT_HTTP_CONTENT_DECODING, 0);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0);
    curl_easy_setopt(curl, CURLOPT_TCP_NODELAY, 1);
    
    PDebug(@"OCSP Request: HTTP GET %@", responder.absoluteString);
    
    CURLcode response = curl_easy_perform(curl);
    if (response != CURLE_OK) {
        long response_code;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
        
        *error = [NSError errorWithDomain:@"CKOCSPManager" code:OCSP_ERROR_HTTP_ERROR userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP Error %ld", response_code]}];
        PError(@"OCSP HTTP Response: %ld", response_code);
        
        curl_easy_cleanup(curl);
        return;
    }
    
    PDebug(@"OCSP HTTP Response: 200");
    
    OCSP_RESPONSE * ocspResponse = [self decodeResponse:self.responseDataBuffer];
    if (ocspResponse == NULL) {
        [self openSSLError];
        *error = [NSError errorWithDomain:@"CKOCSPManager" code:OCSP_ERROR_DECODE_ERROR userInfo:@{NSLocalizedDescriptionKey: @"Error decoding OCSP response."}];
        PError(@"Error decoding OCSP response");
        return;
    }
    int requestResponse = OCSP_response_status(ocspResponse);
    if (requestResponse != OCSP_RESPONSE_STATUS_SUCCESSFUL) {
        *error = [NSError errorWithDomain:@"CKOCSPManager" code:OCSP_ERROR_REQUEST_ERROR userInfo:@{NSLocalizedDescriptionKey: @"OCSP request error."}];
        PError(@"OCSP Response status: %i", requestResponse);
        return;
    }
    
    OCSP_BASICRESP * basicResp = OCSP_response_get1_basic(ocspResponse);
    if (basicResp == NULL) {
        [self openSSLError];
        *error = [NSError errorWithDomain:@"CKOCSPManager" code:OCSP_ERROR_DECODE_ERROR userInfo:@{NSLocalizedDescriptionKey: @"Error decoding OCSP response."}];
        PError(@"Error getting basic OCSP response from OCSP response object");
        return;
    }
    
    *resp = basicResp;
    
    curl_easy_cleanup(curl);

    // Dump curls output to the log file
    if (@available(iOS 11, *)) {
        if (CKLogging.sharedInstance.level == CKLoggingLevelDebug) {
            fflush(curlout);
            fclose(curlout);
            PDebug(@"curl output:\n%s", buf);
            free(buf);
        }
    }
}

size_t ocsp_write_callback(void *buffer, size_t size, size_t nmemb, void *userp) {
    if (userp == NULL) {
        return 0;
    }
    if (size * nmemb == 0 || buffer == NULL) {
        return 0;
    }

    [((__bridge NSMutableData *)userp) appendBytes:buffer length:size * nmemb];
    return size * nmemb;
}

INSERT_OPENSSL_ERROR_METHOD

@end
