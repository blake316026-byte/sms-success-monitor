import Foundation

enum PlatformPagePresentationScript {
  static let capture = #"""
    const previous=window.__smsTabMovePresentation;
    if(previous) previous.dispose();
    const positions=[...document.querySelectorAll('*')]
      .filter(e=>e.scrollTop || e.scrollLeft).slice(0,128).map(e=>[e,e.scrollLeft,e.scrollTop]);
    const state={token,root:document.documentElement,x:scrollX,y:scrollY,positions,cancelled:false};
    const events=['pointerdown','wheel','keydown','touchstart','input'];
    const interrupt=e=>{if(e.isTrusted) state.cancelled=true;};
    state.dispose=()=>{
      for(const event of events) document.removeEventListener(event,interrupt,true);
      clearTimeout(state.expiry);
      if(window.__smsTabMovePresentation===state) delete window.__smsTabMovePresentation;
    };
    for(const event of events) document.addEventListener(event,interrupt,true);
    state.expiry=setTimeout(()=>state.dispose(),3000);
    window.__smsTabMovePresentation=state;
    return token;
    """#

  static let restore = #"""
    await new Promise(resolve=>setTimeout(resolve,120));
    const state=window.__smsTabMovePresentation;
    if(!state || state.token!==token) return false;
    try {
      if(state.cancelled || state.root!==document.documentElement) return false;
      for(const [element,x,y] of state.positions) if(element.isConnected)
        element.scrollTo({left:x,top:y,behavior:'instant'});
      window.scrollTo({left:state.x,top:state.y,behavior:'instant'});
      return true;
    } finally {state.dispose();}
    """#

  static let discard = #"""
    const state=window.__smsTabMovePresentation;
    if(state?.token===token) state.dispose();
    return true;
    """#
}
