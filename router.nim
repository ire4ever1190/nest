import critbits, strutils, parseutils, strtabs, sequtils
from asynchttpserver import Request
import logging

#
#Type Declarations
#

const allowedCharsInUrl = {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/'}
const wildcard = '*'
const startParam = '{'
const endParam = '}'
const specialSectionStartChars = {wildcard, startParam}
const allowedCharsInPattern = allowedCharsInUrl + {wildcard, startParam, endParam}

type
  RequestHandler* = proc (req: Request, headers : var StringTableRef, pathParams : StringTableRef, queryParams : StringTableRef, modelParams : StringTableRef) : string {.gcsafe.}

  MatcherPieceType = enum
    matcherWildcard,
    matcherParam,
    matcherText
  MatcherPiece = object
    case kind : MatcherPieceType:
      of matcherParam, matcherText:
        value : string
      of matcherWildcard:
        discard
  PathMatcher = tuple
    pattern : seq[MatcherPiece]
    headers : StringTableRef
    handler : RequestHandler

  MethodRouter = ref object
    staticPaths : CritBitTree[RequestHandler]
    pathMatchers : seq[PathMatcher]

  Router* = ref object
    methodRouters : CritBitTree[MethodRouter]

  RoutingError = object of Exception

#
#Constructor
#
proc newRouter*() : Router =
  return Router(methodRouters : CritBitTree[MethodRouter]())

proc newMethodRouter() : MethodRouter =
  return MethodRouter(pathMatchers:newSeq[PathMatcher](), staticPaths:CritBitTree[RequestHandler]())

#
#Procedures to add routes
#
proc generatePatternSequence(pattern : string, startIndex : int = 0) : seq[MatcherPiece] {.noSideEffect, raises: [RoutingError].} =
  var token : string
  let tokenSize = pattern.parseUntil(token, specialSectionStartChars, startIndex)
  var newStartIndex = startIndex + tokenSize

  if newStartIndex < pattern.len():
    let specialChar = pattern[newStartIndex]
    newStartIndex += 1

    var scanner : MatcherPiece

    if specialChar == wildcard:
      scanner = MatcherPiece(kind:matcherWildcard)
    elif specialChar == startParam:
      var paramName : string
      let paramNameSize = pattern.parseUntil(paramName, endParam, newStartIndex)
      newStartIndex += (paramNameSize + 1)
      scanner = MatcherPiece(kind:matcherParam, value:paramName)
    else:
      raise newException(RoutingError, "Unrecognized special character")

    return concat(@[MatcherPiece(kind:matcherText, value:token), scanner], generatePatternSequence(pattern, newStartIndex))
  else:
    return @[MatcherPiece(kind:matcherText, value:token)]

proc route*(router : Router, reqMethod : string, pattern : string, handler : RequestHandler, reqHeaders : StringTableRef = newStringTable(), logger : Logger = newConsoleLogger()) {.noSideEffect.} =
  if(not pattern.allCharsInSet(allowedCharsInPattern)):
    raise newException(RoutingError, "Illegal characters occurred in the routing pattern, please restrict to alphanumerics, or the following: - . _ ~ /")

  let reqMethod = reqMethod.toLower()

  #if a url ends in a forward slash, we discard it and consider the matcher the same as without it
  var pattern = pattern
  pattern.removeSuffix('/')

  if not (pattern[0] == '/'): #ensure each pattern is relative to root
    pattern.insert("/")

  var methodRouter : MethodRouter
  try:
    methodRouter = router.methodRouters[reqMethod]
  except KeyError:
    methodRouter = newMethodRouter()
    router.methodRouters[reqMethod] = methodRouter

  if pattern.allCharsInSet(allowedCharsInUrl): #static cases do not need to be matched against
    methodRouter.staticPaths[pattern] = handler
  else:
    methodRouter.pathMatchers.add((pattern:generatePatternSequence(pattern), headers: reqHeaders, handler:handler))

  #TODO: ensure the path does not conflict with an existing one
  logger.log(lvlInfo, "Created ", reqMethod, " mapping for '", pattern, "'")


#
# Procedures to match against paths
#

type
  PathMatchingResultType* = enum
    pathMatchFound
    pathMatchNotFound
  PathMatchingResult* = object
    case status* : PathMatchingResultType:
      of pathMatchFound:
        handler* : RequestHandler
        pathParams* : StringTableRef
      of pathMatchNotFound:
        discard

proc matchPath(matcher : PathMatcher, path : string, logger : Logger) : PathMatchingResult =
  block checkMatch: #a single run, this can be broken if anything checked doesn't match
    var scanningWildcard, scanningParameter = false
    var parameterBeingScanned : string
    var pathIndex = 0
    var pathParams = newStringTable()

    for piece in matcher.pattern:
      case piece.kind:
        of matcherText:
          if scanningWildcard or scanningParameter:
            if piece.value == "": #end of pieces to pattern, close out the scanning
              if scanningParameter:
                pathParams[parameterBeingScanned] = path.substr(pathIndex)
              scanningWildcard = false
              scanningParameter = false
            elif not path.contains(piece.value):
              break checkMatch
            else: #skip forward til end of wildcard, then past the encountered text
              let paramEndIndex = path.find(piece.value, pathIndex) - 1
              if scanningParameter:
                pathParams[parameterBeingScanned] = path.substr(pathIndex, paramEndIndex)
              pathIndex = paramEndIndex + piece.value.len() + 1
              scanningWildcard = false
              scanningParameter = false
          else:
            if path.continuesWith(piece.value, pathIndex):
              pathIndex += piece.value.len()
            else:
              break checkMatch
        of matcherWildcard:
          assert(not scanningWildcard and not scanningParameter)
          scanningWildcard = true
        of matcherParam:
          assert(not scanningWildcard and not scanningParameter)
          scanningParameter = true
          parameterBeingScanned = piece.value

    if not scanningWildcard and not scanningParameter:
      return PathMatchingResult(status:pathMatchFound, handler:matcher.handler, pathParams:pathParams)

  return PathMatchingResult(status:pathMatchNotFound)

proc match*(router : Router, reqMethod : string, path : string, logger : Logger = newConsoleLogger()) : PathMatchingResult {.noSideEffect.} =
  let reqMethod = reqMethod.toLower()

  if router.methodRouters.contains(reqMethod):
    let methodRouter = router.methodRouters[reqMethod]
    var path = path
    if path != "/": #the root string is special
      path.removeSuffix('/') #trailing slashes are considered redundant

    if methodRouter.staticPaths.contains(path): #basic url, see if its in the list on its own first, guaranteed no conflicts with matcher characters
      return PathMatchingResult(status:pathMatchFound, handler: methodRouter.staticPaths[path], pathParams:newStringTable())
    else: #check for a match
      for matcher in methodRouter.pathMatchers: # TODO: could this be sped up by using a CritBitTree and pairsWithPrefix?
        let matchingResult = matcher.matchPath(path, logger)
        case matchingResult.status:
          of pathMatchFound:
            return matchingResult
          of pathMatchNotFound:
            continue

      return PathMatchingResult(status:pathMatchNotFound)
