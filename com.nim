#====================================================================
#
#               Winim - Nim's Windows API Module
#                 (c) Copyright 2016-2017 Ward
#
#           Windows COM Object And COM Event Supports
#
#====================================================================

## This module add windows COM support to Winim.
## So that we can use Nim to interact with COM object like a script language.
## For example:
##
## .. code-block:: Nim
##    comScript:
##      var dict = CreateObject("Scripting.Dictionary")
##      dict.add("a", "the")
##      dict.add("b", "quick")
##      dict.add("c", "fox")
##      dict.item("c") = "dog"
##      for key in dict:
##        echo key, " => ", dict.item(key)
##
## This module introduce two new types to deal with COM objects: "com" and "variant".
## In summary, CreateObject() or GetObject() returned a "com" type value,
## and any input/ouput of COM method should be a "variant" type value.
##
## Most Nim's data type and Winim's string type can convert to/from "variant" type value.
## The conversion is usually done automatically. However, specific conversion is aslo welcome.
##
## .. code-block:: Nim
##    proc toVariant[T](x: T): variant
##    proc fromVariant[T](x: variant): T
##
##      # Supported type:
##      #   char|string|cstring|mstring|wstring|BSTR
##      #   bool|enum|SomeInteger|SomeReal
##      #   com|variant|VARIANT|ptr IUnknown|ptr IDispatch|pointer
##      #   SYSTEMTIME|FILETIME
##      #   1d~3d array|seq
##

{.experimental.} # for dot operators

import strutils, macros, winim
export winim

#todo: is it a good idea to do global initialize here?
# however, it works fine.
discard CoInitialize(nil)

when defined(nontrace):
  const hasTraceTable = false
else:
  const hasTraceTable = true

type
  COMError* = object of Exception
  COMException* = object of COMError
  VariantConversionError* = object of ValueError

proc notNil[T](x: T): bool =
  when T is BSTR: not cast[pointer](x).isNil
  else: not x.isNil

converter voidpp_converter(x: ptr ptr object): ptr pointer = cast[ptr pointer](x)

# make these const store in global scope to avoid repeat init in every proc
discard &IID_NULL
discard &IID_IEnumVARIANT
discard &IID_IClassFactory
discard &IID_IDispatch

type
  com* = ref object
    disp: ptr IDispatch

  variant* = ref object
    raw: VARIANT

  comarray* = seq[variant]
  comarray1d* = seq[variant]
  comarray2d* = seq[seq[variant]]
  comarray3d* = seq[seq[seq[variant]]]

when hasTraceTable:
  import tables

  var
    comTrace {.threadvar.}: TableRef[pointer, bool]
    varTrace {.threadvar.}: TableRef[pointer, bool]

  comTrace = newTable[pointer, bool]()
  varTrace = newTable[pointer, bool]()

proc del*(x: com) =
  when hasTraceTable:
    comTrace.del(cast[pointer](x))

  if x.notNil and x.disp.notNil:
    x.disp.Release()
    x.disp = nil

proc del*(x: variant) =
  when hasTraceTable:
    varTrace.del(cast[pointer](x))

  if x.notNil:
    discard VariantClear(&x.raw)

template init(x): untyped =
  new(x, del)

  when hasTraceTable:
    when x.type is variant:
      varTrace[cast[pointer](x)] = true

    elif x.type is com:
      comTrace[cast[pointer](x)] = true


when hasTraceTable:
  proc COM_FullRelease*() =
    ## Clean up all COM objects and variants.
    ##
    ## Usually, we let garbage collector to release the objects.
    ## However, sometimes the garbage collector can't release all the object even we call GC_fullCollect().
    ## Some object will create a endless process in this situation. (for example: Excel.Application).
    ## So we need this function.
    ##
    ## Use -d:nontrace to disable this function.

    for k, v in varTrace: del cast[variant](k)
    for k, v in comTrace: del cast[com](k)
    varTrace.clear
    comTrace.clear

proc typeDesc(VT: VARTYPE, d: UINT = 0): string =
  if VT == VT_ILLEGAL.VARTYPE:
    result = "VT_ILLEGAL"
  else:
    var vt = VT
    result = ""
    template deflag(e: VARENUM) =
      if (vt and e.VARTYPE) != 0:
        if e == VT_ARRAY and d != 0:
          result &= $e & "(" & $d & "D)|"
        else:
          result &= $e & "|"
        vt = vt and (not e.VARTYPE)

    deflag(VT_VECTOR)
    deflag(VT_BYREF)
    deflag(VT_ARRAY)
    deflag(VT_RESERVED)
    result &= $vt.VARENUM

proc vcErrorMsg(f: string, t: string = nil): string =
  "convert from " & f & " to " & (if t.isNil: f else: t)

proc rawType*(x: variant): VARTYPE =
  result = x.raw.vt

proc rawTypeDesc*(x: variant): string =
  var dimensions: UINT = 0
  if (x.raw.vt and VT_ARRAY.VARTYPE) != 0:
    dimensions = SafeArrayGetDim(x.raw.parray)

  result = x.raw.vt.typeDesc(dimensions)

proc newCom*(x: ptr IDispatch): com =
  result.init
  x.AddRef()
  result.disp = x

proc copy*(x: com): com =
  if x.notNil:
    result = newCom(x.disp)

proc warp*(x: ptr IDispatch): com =
  result = newCom(x)

proc unwarp*(x: com): ptr IDispatch =
  result = x.disp

proc newVariant*(x: VARIANT): variant =
  result.init
  if VariantCopy(&result.raw, x.unsafeaddr).FAILED:
    raise newException(VariantConversionError, vcErrorMsg(x.vt.typeDesc))

proc copy*(x: variant): variant =
  if x.notNil:
    result.init
    if VariantCopy(&result.raw, x.raw.unsafeaddr).FAILED:
      raise newException(VariantConversionError, vcErrorMsg(x.raw.vt.typeDesc))

proc toVariant*(x: string|cstring|mstring): variant =
  result.init
  result.raw.vt = VT_BSTR.VARTYPE
  result.raw.bstrVal = SysAllocString(&(+$x))

proc toVariant*(x: wstring): variant =
  result.init
  result.raw.vt = VT_BSTR.VARTYPE
  result.raw.bstrVal = SysAllocString(&x)

proc toVariant*(x: BSTR): variant =
  result.init
  result.raw.vt = VT_BSTR.VARTYPE
  result.raw.bstrVal = SysAllocString(x)

proc toVariant*(x: bool): variant =
  result.init
  result.raw.vt = VT_BOOL.VARTYPE
  result.raw.boolVal = if x: VARIANT_TRUE else: VARIANT_FALSE

proc toVariant*(x: SomeInteger|enum): variant =
  result.init
  when x.type is SomeSignedInt:
    when sizeof(x) == 1:
      result.raw.vt = VT_I1.VARTYPE
      result.raw.bVal = cast[uint8](x)
    elif sizeof(x) == 2:
      result.raw.vt = VT_I2.VARTYPE
      result.raw.iVal = x.int16
    elif sizeof(x) == 4:
      result.raw.vt = VT_I4.VARTYPE
      result.raw.lVal = x.int32
    else:
      result.raw.vt = VT_I8.VARTYPE
      result.raw.llVal = x.int64
  else:
    when sizeof(x) == 1:
      result.raw.vt = VT_UI1.VARTYPE
      result.raw.bVal = x.uint8
    elif sizeof(x) == 2:
      result.raw.vt = VT_UI2.VARTYPE
      result.raw.uiVal = x.uint16
    elif sizeof(x) == 4:
      result.raw.vt = VT_UI4.VARTYPE
      result.raw.ulVal = x.uint32
    else:
      result.raw.vt = VT_UI8.VARTYPE
      result.raw.ullVal = x.uint64

proc toVariant*(x: SomeReal): variant =
  result.init
  when sizeof(x) == 4:
    result.raw.vt = VT_R4.VARTYPE
    result.raw.fltVal = x.float32
  else:
    result.raw.vt = VT_R8.VARTYPE
    result.raw.dblVal = x.float64

proc toVariant*(x: char): variant =
  result.init
  result.raw.vt = VT_UI1.VARTYPE
  result.raw.bVal = x.byte

proc toVariant*(x: pointer): variant =
  result.init
  result.raw.vt = VT_PTR.VARTYPE
  result.raw.byref = x

proc toVariant*(x: ptr IDispatch): variant =
  result.init
  x.AddRef()
  result.raw.vt = VT_DISPATCH.VARTYPE
  result.raw.pdispVal = x

proc toVariant*(x: com): variant =
  result.init
  x.disp.AddRef()
  result.raw.vt = VT_DISPATCH.VARTYPE
  result.raw.pdispVal = x.disp

proc toVariant*(x: ptr IUnknown): variant =
  result.init
  x.AddRef()
  result.raw.vt = VT_UNKNOWN.VARTYPE
  result.raw.punkVal = x

proc toVariant*(x: SYSTEMTIME): variant =
  result.init
  result.raw.vt = VT_DATE.VARTYPE
  if SystemTimeToVariantTime(x.unsafeaddr, &result.raw.u1.s1.u1.date) == FALSE:
    raise newException(VariantConversionError, vcErrorMsg("SYSTEMTIME", "VT_DATE"))

proc toVariant*(x: FILETIME): variant =
  result.init
  var st: SYSTEMTIME
  result.raw.vt = VT_DATE.VARTYPE
  if FileTimeToSystemTime(x.unsafeaddr, &st) == FALSE or SystemTimeToVariantTime(&st, &result.raw.u1.s1.u1.date) == FALSE:
    raise newException(VariantConversionError, vcErrorMsg("FILETIME", "VT_DATE"))

proc toVariant*(x: ptr SomeInteger|ptr SomeReal|ptr char|ptr bool|ptr BSTR): variant =
  result = toVariant(x[])
  result.raw.byref = cast[pointer](x)
  result.raw.vt = result.raw.vt or VT_BYREF.VARTYPE

proc toVariant*(x: VARIANT): variant =
  result.init
  if VariantCopy(&result.raw, x.unsafeaddr).FAILED:
    raise newException(VariantConversionError, vcErrorMsg(x.vt.typeDesc))

proc toVariant*(x: variant): variant =
  result.init
  if x.isNil: # nil.variant for missing optional parameters
    result.raw.vt = VT_ERROR.VARTYPE
    result.raw.scode = DISP_E_PARAMNOTFOUND
  else:
    result = x.copy

template toVariant1D(x: typed, vt: VARENUM) =
  var sab: array[1, SAFEARRAYBOUND]
  sab[0].cElements = x.len.ULONG
  result.raw.parray = SafeArrayCreate(vt.VARTYPE, 1, &sab[0])
  if result.raw.parray == nil:
    raise newException(VariantConversionError, vcErrorMsg("openarray", (vt.VARTYPE or VT_ARRAY.VARTYPE).typeDesc(1)))

  for i in 0..<x.len:
    var
      v = toVariant(x[i])
      indices = i.LONG

    if vt == VT_VARIANT:
      discard SafeArrayPutElement(result.raw.parray, &indices, &(v.raw))
    elif vt == VT_DISPATCH or vt == VT_UNKNOWN or vt == VT_BSTR:
      discard SafeArrayPutElement(result.raw.parray, &indices, (v.raw.u1.s1.u1.byref))
    else:
      discard SafeArrayPutElement(result.raw.parray, &indices, &(v.raw.u1.s1.u1.intVal))

template toVariant2D(x: typed, vt: VARENUM) =
  var sab: array[2, SAFEARRAYBOUND]
  sab[0].cElements = x.len.ULONG

  for i in 0..<x.len:
    if x[i].len.ULONG > sab[1].cElements: sab[1].cElements = x[i].len.ULONG

  result.raw.parray = SafeArrayCreate(vt.VARTYPE, 2, &sab[0])
  if result.raw.parray == nil:
    raise newException(VariantConversionError, vcErrorMsg("openarray", (vt.VARTYPE or VT_ARRAY.VARTYPE).typeDesc(2)))

  for i in 0..<x.len:
    for j in 0..<x[i].len:
      var
        v = toVariant(x[i][j])
        indices = [i.LONG, j.LONG]

      if vt == VT_VARIANT:
        discard SafeArrayPutElement(result.raw.parray, &indices[0], &(v.raw))
      elif vt == VT_DISPATCH or vt == VT_UNKNOWN or vt == VT_BSTR:
        discard SafeArrayPutElement(result.raw.parray, &indices[0], (v.raw.u1.s1.u1.byref))
      else:
        discard SafeArrayPutElement(result.raw.parray, &indices[0], &(v.raw.u1.s1.u1.intVal))

template toVariant3D(x: typed, vt: VARENUM) =
  var sab: array[3, SAFEARRAYBOUND]
  sab[0].cElements = x.len.ULONG

  for i in 0..<x.len:
    if x[i].len.ULONG > sab[1].cElements: sab[1].cElements = x[i].len.ULONG
    for j in 0..<x[i].len:
      if x[i][j].len.ULONG > sab[2].cElements: sab[2].cElements = x[i][j].len.ULONG

  result.raw.parray = SafeArrayCreate(vt.VARTYPE, 3, &sab[0])
  if result.raw.parray == nil:
    raise newException(VariantConversionError, vcErrorMsg("openarray", (vt.VARTYPE or VT_ARRAY.VARTYPE).typeDesc(3)))

  for i in 0..<x.len:
    for j in 0..<x[i].len:
      for k in 0..<x[i][j].len:
        var
          v = toVariant(x[i][j][k])
          indices = [i.LONG, j.LONG, k.LONG]

        if vt == VT_VARIANT:
          discard SafeArrayPutElement(result.raw.parray, &indices[0], &(v.raw))
        elif vt == VT_DISPATCH or vt == VT_UNKNOWN or vt == VT_BSTR:
          discard SafeArrayPutElement(result.raw.parray, &indices[0], (v.raw.u1.s1.u1.byref))
        else:
          discard SafeArrayPutElement(result.raw.parray, &indices[0], &(v.raw.u1.s1.u1.intVal))

proc toVariant*[T](x: openarray[T], vt: VARENUM = VT_VARIANT): variant =
  result.init
  result.raw.vt = VT_ARRAY.VARTYPE or vt.VARTYPE

  when x[0].type is array|seq:
    when x[0][0].type is array|seq:
      when x[0][0][0].type is array|seq:
        raise newException(VariantConversionError, vcErrorMsg("openarray", (vt.VARTYPE or VT_ARRAY.VARTYPE).typeDesc(4)))
      else:
        toVariant3D(x, vt)
    else:
      toVariant2D(x, vt)
  else:
    toVariant1D(x, vt)

template fromVariant1D(x, dimensions: typed) =
  var
    vt: VARTYPE
    xUbound, xLbound: LONG

  if SafeArrayGetVartype(x.raw.parray, &vt).SUCCEEDED and dimensions == 1 and
    SafeArrayGetLBound(x.raw.parray, 1, &xLbound).SUCCEEDED and
    SafeArrayGetUBound(x.raw.parray, 1, &xUbound).SUCCEEDED:

    var xLen = xUbound - xLbound + 1
    newSeq(result, xLen)
    for i in 0..<xLen:
      var indices = i.LONG + xLbound
      result[i].init
      if vt == VT_VARIANT.VARTYPE:
        discard SafeArrayGetElement(x.raw.parray, &indices, &result[i].raw)
      else:
        result[i].raw.vt = vt
        discard SafeArrayGetElement(x.raw.parray, &indices, &result[i].raw.u1.s1.u1.intVal)

  else:
    raise newException(VariantConversionError, vcErrorMsg(x.raw.vt.typeDesc(dimensions), "comarray1d"))

template fromVariant2D(x, dimensions: typed) =
  var
    vt: VARTYPE
    xUbound, xLbound: LONG
    yUbound, yLbound: LONG

  if SafeArrayGetVartype(x.raw.parray, &vt).SUCCEEDED and dimensions == 2 and
    SafeArrayGetLBound(x.raw.parray, 1, &xLbound).SUCCEEDED and
    SafeArrayGetUBound(x.raw.parray, 1, &xUbound).SUCCEEDED and
    SafeArrayGetLBound(x.raw.parray, 2, &yLbound).SUCCEEDED and
    SafeArrayGetUBound(x.raw.parray, 2, &yUbound).SUCCEEDED:

    var
      xLen = xUbound - xLbound + 1
      yLen = yUbound - yLbound + 1

    newSeq(result, xLen)
    for i in 0..<xLen:
      newSeq(result[i], yLen)
      for j in 0..<yLen:
        var indices = [i.LONG + xLbound, j.LONG + yLbound]
        result[i][j].init
        if vt == VT_VARIANT.VARTYPE:
          discard SafeArrayGetElement(x.raw.parray, &indices[0], &result[i][j].raw)
        else:
          result[i][j].raw.vt = vt
          discard SafeArrayGetElement(x.raw.parray, &indices[0], &result[i][j].raw.u1.s1.u1.intVal)

  else:
    raise newException(VariantConversionError, vcErrorMsg(x.raw.vt.typeDesc(dimensions), "comarray2d"))

template fromVariant3D(x, dimensions: typed) =
  var
    vt: VARTYPE
    xUbound, xLbound: LONG
    yUbound, yLbound: LONG
    zUbound, zLbound: LONG

  if SafeArrayGetVartype(x.raw.parray, &vt).SUCCEEDED and dimensions == 3 and
    SafeArrayGetLBound(x.raw.parray, 1, &xLbound).SUCCEEDED and
    SafeArrayGetUBound(x.raw.parray, 1, &xUbound).SUCCEEDED and
    SafeArrayGetLBound(x.raw.parray, 2, &yLbound).SUCCEEDED and
    SafeArrayGetUBound(x.raw.parray, 2, &yUbound).SUCCEEDED and
    SafeArrayGetLBound(x.raw.parray, 3, &zLbound).SUCCEEDED and
    SafeArrayGetUBound(x.raw.parray, 3, &zUbound).SUCCEEDED:

    var
      xLen = xUbound - xLbound + 1
      yLen = yUbound - yLbound + 1
      zLen = zUbound - zLbound + 1

    newSeq(result, xLen)
    for i in 0..<xLen:
      newSeq(result[i], yLen)
      for j in 0..<yLen:
        newSeq(result[i][j], zLen)
        for k in 0..<zLen:
          var indices = [i.LONG + xLbound, j.LONG + yLbound, k.LONG + zLbound]
          result[i][j][k].init
          if vt == VT_VARIANT.VARTYPE:
            discard SafeArrayGetElement(x.raw.parray, &indices[0], &result[i][j][k].raw)
          else:
            result[i][j][k].raw.vt = vt
            discard SafeArrayGetElement(x.raw.parray, &indices[0], &result[i][j][k].raw.u1.s1.u1.intVal)

  else:
    raise newException(VariantConversionError, vcErrorMsg(x.raw.vt.typeDesc(dimensions), "comarray3d"))

proc fromVariant*[T](x: variant): T =
  if x.isNil: return

  when T is VARIANT:
    result = x.raw

  else:
    const VT_BYREF_VARIANT = VT_BYREF.VARTYPE or VT_VARIANT.VARTYPE
    if (x.raw.vt and VT_BYREF_VARIANT) == VT_BYREF_VARIANT:
      var v: VARIANT = x.raw.pvarVal[]
      return fromVariant[T](newVariant(v))

    var dimensions: UINT = 0
    if (x.raw.vt and VT_ARRAY.VARTYPE) != 0:
      dimensions = SafeArrayGetDim(x.raw.parray)

    when T is comarray1d: fromVariant1D(x, dimensions)
    elif T is comarray2d: fromVariant2D(x, dimensions)
    elif T is comarray3d: fromVariant3D(x, dimensions)
    elif T is ptr and not (T is ptr IDispatch) and not (T is ptr IUnknown):
      if (x.raw.vt and VT_BYREF.VARTYPE) != 0:
        result = cast[T](x.raw.byref)

      else:
        raise newException(VariantConversionError, vcErrorMsg(x.raw.vt.typeDesc, "unsupported type"))

    else:
      var
        ret: VARIANT
        targetVt: VARENUM
        targetName: string

      when T is string:         targetVt = VT_BSTR;     targetName = "string"
      elif T is cstring:        targetVt = VT_BSTR;     targetName = "cstring"
      elif T is mstring:        targetVt = VT_BSTR;     targetName = "mstring"
      elif T is wstring:        targetVt = VT_BSTR;     targetName = "wstring"
      elif T is char:           targetVt = VT_UI1;      targetName = "char"
      elif T is SomeInteger:    targetVt = VT_I8;       targetName = "integer"
      elif T is SomeReal:       targetVt = VT_R8;       targetName = "float"
      elif T is bool:           targetVt = VT_BOOL;     targetName = "bool"
      elif T is com:            targetVt = VT_DISPATCH; targetName = "com object"
      elif T is ptr IDispatch:  targetVt = VT_DISPATCH; targetName = "ptr IDispatch"
      elif T is ptr IUnknown:   targetVt = VT_UNKNOWN;  targetName = "ptr IUnknown"
      elif T is pointer:        targetVt = VT_PTR;      targetName = "pointer"
      elif T is FILETIME:       targetVt = VT_DATE;     targetName = "FILETIME"
      elif T is SYSTEMTIME:     targetVt = VT_DATE;     targetName = "SYSTEMTIME"
      else: {.fatal: "trying to do unsupported type conversion.".}

      var
        hr: HRESULT
        needClear: bool

      if x.raw.vt == targetVt.VARTYPE:
        hr = S_OK
        needClear = false
        ret = x.raw
      else:
        hr = VariantChangeType(&ret, x.raw.unsafeaddr, 16, targetVt.VARTYPE)
        needClear = true

      defer:
        if needClear: discard VariantClear(&ret)

      if hr.FAILED:
        raise newException(VariantConversionError, vcErrorMsg(x.raw.vt.typeDesc(dimensions), targetName))

      when T is string:
        result = $ret.bstrVal

      elif T is cstring:
        result = cstring($ret.bstrVal)

      elif T is mstring:
        result = -$ret.bstrVal

      elif T is wstring:
        result = +$ret.bstrVal

      elif T is SYSTEMTIME:
        if VariantTimeToSystemTime(ret.date, &result) == FALSE:
          raise newException(VariantConversionError, vcErrorMsg(x.raw.vt.typeDesc(dimensions), targetName))

      elif T is FILETIME:
        var st: SYSTEMTIME
        if VariantTimeToSystemTime(ret.date, &st) == FALSE or SystemTimeToFileTime(&st, &result) == FALSE:
          raise newException(VariantConversionError, vcErrorMsg(x.raw.vt.typeDesc(dimensions), targetName))

      elif T is com:
        result = newCom(ret.pdispVal)

      elif T is ptr IDispatch:
        ret.pdispVal.AddRef()
        result = ret.pdispVal

      elif T is ptr IUnknown:
        ret.punkVal.AddRef()
        result = ret.punkVal

      elif T is pointer:
        result = ret.byref

      elif T is SomeInteger:  result = cast[T](ret.llVal)
      elif T is SomeReal:     result = T(ret.dblVal)
      elif T is char:         result = char(ret.bVal)
      elif T is bool:         result = if ret.boolVal != 0: true else: false

proc `$`*(x: variant): string = fromVariant[string](x)
converter variantConverter*(x: variant): string = fromVariant[string](x)
converter variantConverter*(x: variant): cstring = fromVariant[cstring](x)
converter variantConverter*(x: variant): mstring = fromVariant[mstring](x)
converter variantConverter*(x: variant): wstring = fromVariant[wstring](x)
converter variantConverter*(x: variant): char = fromVariant[char](x)
converter variantConverter*(x: variant): bool = fromVariant[bool](x)
converter variantConverter*(x: variant): com = fromVariant[com](x)
converter variantConverter*(x: variant): ptr IDispatch = fromVariant[ptr IDispatch](x)
converter variantConverter*(x: variant): ptr IUnknown = fromVariant[ptr IUnknown](x)
converter variantConverter*(x: variant): pointer = fromVariant[pointer](x)
converter variantConverter*(x: variant): int = fromVariant[int](x)
converter variantConverter*(x: variant): uint = fromVariant[uint](x)
converter variantConverter*(x: variant): int8 = fromVariant[int8](x)
converter variantConverter*(x: variant): uint8 = fromVariant[uint8](x)
converter variantConverter*(x: variant): int16 = fromVariant[int16](x)
converter variantConverter*(x: variant): uint16 = fromVariant[uint16](x)
converter variantConverter*(x: variant): int32 = fromVariant[int32](x)
converter variantConverter*(x: variant): uint32 = fromVariant[uint32](x)
converter variantConverter*(x: variant): int64 = fromVariant[int64](x)
converter variantConverter*(x: variant): uint64 = fromVariant[uint64](x)
converter variantConverter*(x: variant): float32 = fromVariant[float32](x)
converter variantConverter*(x: variant): float64 = fromVariant[float64](x)
converter variantConverter*(x: variant): FILETIME = fromVariant[FILETIME](x)
converter variantConverter*(x: variant): SYSTEMTIME = fromVariant[SYSTEMTIME](x)
converter variantConverter*(x: variant): VARIANT = fromVariant[VARIANT](x)
converter variantConverter*(x: variant): comarray1d = fromVariant[comarray1d](x)
converter variantConverter*(x: variant): comarray2d = fromVariant[comarray2d](x)
converter variantConverter*(x: variant): comarray3d = fromVariant[comarray3d](x)

proc invokeRaw(self: com, name: string, invokeType: WORD, vargs: varargs[variant, toVariant]): variant =
  if vargs.len > 128:
    raise newException(COMError, "too mary parameters")

  var
    i = 0
    j = vargs.len - 1
    args: array[128, VARIANT]

  while i < vargs.len:
    args[j] = vargs[i].raw
    j.dec
    i.inc

  var
    dp: DISPPARAMS
    dispidNamed: DISPID = DISPID_PROPERTYPUT
    dispid: DISPID
    ret: VARIANT
    excep: EXCEPINFO
    wstr = allocWString(name)
    pwstr = &(cast[wstring](wstr))

  defer: dealloc(wstr)

  if self.disp.GetIDsOfNames(&IID_NULL, cast[ptr LPOLESTR](&pwstr), 1, LOCALE_USER_DEFAULT, &dispid).FAILED:
    raise newException(COMError, "unsupported method: " & name)

  if vargs.len != 0:
    dp.rgvarg = &args[0]
    dp.cArgs = vargs.len.DWORD

    if (invokeType and (DISPATCH_PROPERTYPUT or DISPATCH_PROPERTYPUTREF)) != 0:
      dp.rgdispidNamedArgs = &dispidNamed
      dp.cNamedArgs = 1

  if self.disp.Invoke(dispid, &IID_NULL, LOCALE_USER_DEFAULT, invokeType, &dp, &ret, &excep, nil).FAILED:
    if excep.pfnDeferredFillIn.notNil:
      discard excep.pfnDeferredFillIn(&excep)

    if excep.bstrSource.notNil:
      var err = $toVariant(excep.bstrSource)
      if excep.bstrDescription.notNil: err &= ": " & $toVariant(excep.bstrDescription)
      SysFreeString(excep.bstrSource)
      SysFreeString(excep.bstrDescription)
      SysFreeString(excep.bstrHelpFile)
      raise newException(COMException, err)

    raise newException(COMError, "invoke method failed: " & name)

  result = newVariant(ret)
  discard VariantClear(&ret)

proc invoke(self: com, name: string, invokeType: WORD, vargs: varargs[variant, toVariant]): variant =
  if self.isNil: return nil

  var
    list = name.split(".")
    obj = self

  for i in 0..list.high-1:
    obj = obj.invokeRaw(list[i], DISPATCH_METHOD or DISPATCH_PROPERTYGET).com

  result = obj.invokeRaw(list[list.high], invokeType, vargs)

proc call*(self: com, name: string, vargs: varargs[variant, toVariant]): variant {.discardable.} =
  result = invoke(self, name, DISPATCH_METHOD, vargs)

proc set*(self: com, name: string, vargs: varargs[variant, toVariant]): variant {.discardable.} =
  result = invoke(self, name, DISPATCH_PROPERTYPUT, vargs)

proc setRef*(self: com, name: string, vargs: varargs[variant, toVariant]): variant {.discardable.} =
  result = invoke(self, name, DISPATCH_PROPERTYPUTREF, vargs)

proc get*(self: com, name: string, vargs: varargs[variant, toVariant]): variant =
  result = invoke(self, name, DISPATCH_METHOD or DISPATCH_PROPERTYGET, vargs)

proc getT*[T](self: com, name: string, vargs: varargs[variant, toVariant]): T =
  result = fromVariant[T](invoke(self, name, DISPATCH_METHOD or DISPATCH_PROPERTYGET, vargs))

iterator items*(x: com): variant =
  var
    ret, item: VARIANT
    dp: DISPPARAMS
    enumvar: ptr IEnumVARIANT

  if x.disp.Invoke(DISPID_NEWENUM, &IID_NULL, LOCALE_USER_DEFAULT, DISPATCH_METHOD or DISPATCH_PROPERTYGET, &dp, &ret, nil, nil).FAILED:
    raise newException(COMError, "object is not iterable")

  if ret.punkVal.QueryInterface(&IID_IEnumVARIANT, &enumvar).FAILED:
    raise newException(COMError, "object is not iterable")

  while enumvar.Next(1, &item, nil) == 0:
    yield newVariant(item)
    discard VariantClear(&item)

  enumvar.Release()
  ret.punkVal.Release()

iterator items*(x: variant): variant =
  var obj = x.com
  for v in obj:
    yield v

proc GetCLSID(progId: string, clsid: var GUID): HRESULT =
  if progId[0] == '{':
    result = CLSIDFromString(progId, &clsid)
  else:
    result = CLSIDFromProgID(progId, &clsid)

proc CreateObject*(progId: string): com =
  ## Creates a reference to a COM object.

  result.init
  var
    clsid: GUID
    pCf: ptr IClassFactory

  if GetCLSID(progId, clsid).SUCCEEDED:
    # better than CoCreateInstance:
    # some IClassFactory.CreateInstance return SUCCEEDED with nil pointer, this crash CoCreateInstance
    # for example: {D5F7E36B-5B38-445D-A50F-439B8FCBB87A}
    if CoGetClassObject(&clsid, CLSCTX_LOCAL_SERVER or CLSCTX_INPROC_SERVER, nil, &IID_IClassFactory, &pCf).SUCCEEDED:
      defer: pCf.Release()

      if pCf.CreateInstance(nil, &IID_IDispatch, &(result.disp)).SUCCEEDED and result.disp.notNil:
        return result

  raise newException(COMError, "unable to create object from " & progId)


proc GetObject*(file: string, progId: string = nil): com =
  ## Retrieves a reference to a COM object from an existing process or filename.

  proc isVaild(x: string): bool = not x.isNilOrEmpty()

  result.init
  var
    clsid: GUID
    pUk: ptr IUnknown
    pPf: ptr IPersistFile

  if progId.isVaild:
    if GetCLSID(progId, clsid).SUCCEEDED:
      if file.isVaild:
        if CoCreateInstance(&clsid, nil, CLSCTX_LOCAL_SERVER or CLSCTX_INPROC_SERVER, &IID_IPersistFile, &pPf).SUCCEEDED:
          defer: pPf.Release()

          if pPf.Load(file, 0).SUCCEEDED and pPf.QueryInterface(&IID_IDispatch, &(result.disp)).SUCCEEDED:
            return result
      else:
        if GetActiveObject(&clsid, nil, &pUk).SUCCEEDED:
          defer: pUk.Release()

          if pUk.QueryInterface(&IID_IDispatch, &(result.disp)).SUCCEEDED:
            return result

  elif file.isVaild:
    if CoGetObject(file, nil, &IID_IDispatch, &(result.disp)).SUCCEEDED:
      return result

  raise newException(COMError, "unable to get object")

proc newCom*(progId: string): com =
  result = CreateObject(progId)

proc newCom*(file, progId: string): com =
  result = GetObject(file, progId)


type
  comEventHandler* = proc(self: com, name: string, params: varargs[variant]): variant
  SinkObj {.pure.} = object
    lpVtbl: ptr IDispatchVtbl
    typeInfo: ptr ITypeInfo
    iid: GUID
    refCount: ULONG
    handler: comEventHandler
    parent: com
  Sink {.pure.} = ptr SinkObj

proc Sink_QueryInterface(self: ptr IUnknown, riid: ptr IID, pvObject: ptr pointer): HRESULT {.stdcall.} =
  var this = cast[Sink](self)
  if IsEqualGUID(riid, &IID_IUnknown) or IsEqualGUID(riid, &IID_IDispatch) or IsEqualGUID(riid, &this.iid):
    pvObject[] = self
    self.AddRef()
    result = S_OK
  else:
    pvObject[] = nil
    result = E_NOINTERFACE

proc Sink_AddRef(self: ptr IUnknown): ULONG {.stdcall.} =
  var this = cast[Sink](self)
  this.refCount.inc
  result = this.refCount

proc Sink_Release(self: ptr IUnknown): ULONG {.stdcall.} =
  var this = cast[Sink](self)
  this.refCount.dec
  if this.refCount == 0:
    this.typeInfo.Release()
    dealloc(self)
    result = 0
  else:
    result = this.refCount

proc Sink_GetTypeInfoCount(self: ptr IDispatch, pctinfo: ptr UINT): HRESULT {.stdcall.} =
  pctinfo[] = 1
  result = S_OK

proc Sink_GetTypeInfo(self: ptr IDispatch, iTInfo: UINT, lcid: LCID, ppTInfo: ptr LPTYPEINFO): HRESULT {.stdcall.} =
  var this = cast[Sink](self)
  ppTInfo[] = this.typeInfo
  this.typeInfo.AddRef()
  result = S_OK

proc Sink_GetIDsOfNames(self: ptr IDispatch, riid: REFIID, rgszNames: ptr LPOLESTR, cNames: UINT, lcid: LCID, rgDispId: ptr DISPID): HRESULT {.stdcall.} =
  var this = cast[Sink](self)
  result = DispGetIDsOfNames(this.typeInfo, rgszNames, cNames, rgDispId)

proc Sink_Invoke(self: ptr IDispatch, dispid: DISPID, riid: REFIID, lcid: LCID, wFlags: WORD, params: ptr DISPPARAMS, ret: ptr VARIANT, pExcepInfo: ptr EXCEPINFO, puArgErr: ptr UINT): HRESULT {.stdcall, thread.} =
  var this = cast[Sink](self)
  var
    bname: BSTR
    nameCount: UINT
    vret: variant
    name: string
    args = cast[ref array[100_000, VARIANT]](params.rgvarg)
    sargs = newSeq[variant]()
    total = params.cArgs + params.cNamedArgs

  result = this.typeInfo.GetNames(dispid, &bname, 1, &nameCount)
  if result.SUCCEEDED:
    name = $bname
    SysFreeString(bname)

    for i in 1..total:
      sargs.add(newVariant(args[total-i]))

    try:
      vret = this.handler(this.parent, name, sargs)

    except:
      let e = getCurrentException()
      echo "uncatched exception inside event hander: " & $e.name & " (" & $e.msg & ")"

    finally:
      if vret.notNil and ret.notNil:
        result = VariantCopy(ret, &vret.raw)
      else:
        result = S_OK

let
  SinkVtbl: IDispatchVtbl = IDispatchVtbl(
    QueryInterface: Sink_QueryInterface,
    AddRef: Sink_AddRef,
    Release: Sink_Release,
    GetTypeInfoCount: Sink_GetTypeInfoCount,
    GetTypeInfo: Sink_GetTypeInfo,
    GetIDsOfNames: Sink_GetIDsOfNames,
    Invoke: Sink_Invoke
  )

proc newSink(parent: com, iid: GUID, typeInfo: ptr ITypeInfo, handler: comEventHandler): Sink =
  result = cast[Sink.type](alloc0(sizeof(SinkObj)))
  result.lpVtbl = SinkVtbl.unsafeaddr
  result.parent = parent
  result.iid = iid
  result.typeInfo = typeInfo
  typeInfo.AddRef()
  result.handler = handler


proc connectRaw(self: com, riid: REFIID = nil, cookie: DWORD, handler: comEventHandler = nil): DWORD =
  var
    iid: IID
    count, index: UINT
    typeInfo, dispTypeInfo: ptr ITypeInfo
    connection: ptr IConnectionPoint
    typeLib: ptr ITypeLib
    container: ptr IConnectionPointContainer
    enu: ptr IEnumConnectionPoints
    sink: Sink

  defer:
    if typeInfo.notNil: typeInfo.Release()
    if dispTypeInfo.notNil: dispTypeInfo.Release()
    if connection.notNil: connection.Release()
    if typeLib.notNil: typeLib.Release()
    if container.notNil: container.Release()
    if enu.notNil: enu.Release()

  block:
    if self.disp.GetTypeInfoCount(&count).FAILED or count != 1: break
    if self.disp.GetTypeInfo(0, 0, &dispTypeInfo).FAILED: break
    if dispTypeInfo.GetContainingTypeLib(&typeLib, &index).FAILED: break
    if self.disp.QueryInterface(&IID_IConnectionPointContainer, &container).FAILED: break

    if riid.isNil:
      if container.EnumConnectionPoints(&enu).FAILED: break
      enu.Reset()
      while enu.Next(1, &connection, nil) != S_FALSE:
        if connection.GetConnectionInterface(&iid).SUCCEEDED and
          typeLib.GetTypeInfoOfGuid(&iid, &typeInfo).SUCCEEDED:
            break

        connection.Release()
        connection = nil

    else:
      if container.FindConnectionPoint(riid, &connection).FAILED: break
      if connection.GetConnectionInterface(&iid).FAILED: break
      if typeLib.GetTypeInfoOfGuid(riid, &typeInfo).FAILED: break

    if handler.notNil:
      sink = newSink(self, iid, typeInfo, handler)
      if connection.Advise(cast[ptr IUnknown](sink), &result).FAILED: result = 0

    elif cookie != 0:
      if connection.Unadvise(cookie).SUCCEEDED: result = 1


proc connect*(self: com, handler: comEventHandler, riid: REFIID = nil): DWORD {.discardable.} =
  ## Connect a COM object to a comEventHandler. Return a cookie to disconnect (if needed).
  ## Handler is a user defined proc to receive the COM event.
  ## comEventHandler is defined as:
  ##
  ## .. code-block:: Nim
  ##    type comEventHandler = proc(self: com, name: string, params: varargs[variant]): variant

  if handler.notNil:
    result = connectRaw(self, riid, 0, handler)

proc disconnect*(self: com, cookie: DWORD, riid: REFIID = nil): bool {.discardable.} =
  ## Disconnect a COM object from a comEventHandler.

  if cookie != 0 and connectRaw(self, riid, cookie, nil) != 0:
    result = true

proc `.`*(self: com, name: string, vargs: varargs[variant, toVariant]): variant {.discardable.} =
  result = invoke(self, name, DISPATCH_METHOD or DISPATCH_PROPERTYGET, vargs)

proc `.=`*(self: com, name: string, vargs: varargs[variant, toVariant]): variant {.discardable.} =
  result = invoke(self, name, DISPATCH_PROPERTYPUT, vargs)

proc `.()`*(self: com, name: string, vargs: varargs[variant, toVariant]): variant {.discardable.} =
  result = invoke(self, name, DISPATCH_METHOD or DISPATCH_PROPERTYGET, vargs)


proc comReformat(n: NimNode): NimNode =
  # reformat code: a.b.c(d, e) = f becomes a.b.c.set(d, e, f)

  result = n

  if n.kind == nnkAsgn and n[0].kind == nnkCall and n[0][0].kind == nnkDotExpr:
    let
      params = n[0]
      dots = n[0][0]

    params.insert(1, dots.last.toStrLit)
    params.add(n.last)
    dots.del(dots.len-1)
    dots.add(newIdentNode("set"))

    result = n[0]

  elif n.len != 0:
    for i in 0..<n.len:
      let node = comReformat(n[i])
      n.del(i)
      n.insert(i, node)

macro comScript*(x: untyped): untyped =
  ## Nim's dot operators `.=` only allow "a.b = c".
  ## With this macro, "a.b(c, d) = e" is allowed.
  ## Some assignment need this macro. For example:
  ##
  ## .. code-block:: Nim
  ##    comScript:
  ##      dict.item("c") = "dog"
  ##      excel.activeSheet.cells(1, 1) = "text"

  result = comReformat(x)

when isMainModule:

  comScript:
    var dict = CreateObject("Scripting.Dictionary")
    dict.add("a", "the")
    dict.add("b", "quick")
    dict.add("c", "fox")
    dict.item("c") = "dog" # this line needs comScript macro

    for key in dict:
      echo key, " => ", dict.item(key)
