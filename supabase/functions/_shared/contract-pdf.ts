import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";
type ContractModule={id:string;title:string;body:string;active:boolean};
const contractText=(text:string,employee:any)=>{const salaryType=employee.salary_type==="hourly"?"time":employee.salary_type==="monthly"?"måned":"[time/måned]",rate=employee.salary_rate==null?"[beløp]":Number(employee.salary_rate).toLocaleString("nb-NO",{minimumFractionDigits:2,maximumFractionDigits:2});return String(text).replaceAll("[dato]",employee.employed_from||"[dato]").replaceAll("[prosent]",employee.position_percent==null?"[prosent]":String(employee.position_percent)).replaceAll("[beløp]",rate).replaceAll("[time/måned]",salaryType)};
export const contractPdf=async(contract:any,employee:any,employerName:string,sandbox=false)=>{
  const pdf=await PDFDocument.create(),font=await pdf.embedFont(StandardFonts.Helvetica),bold=await pdf.embedFont(StandardFonts.HelveticaBold);
  const width=595,height=842,margin=58,maxWidth=width-margin*2,lineHeight=14;let page=pdf.addPage([width,height]),y=height-58,pageNumber=1;
  const footer=()=>{if(sandbox)page.drawText("TEST - SIGNICAT SANDBOX",{x:margin,y:44,size:9,font:bold,color:rgb(.6,.15,.1)});page.drawText(String(pageNumber),{x:width/2-3,y:28,size:9,font,color:rgb(.35,.35,.35)})};
  const nextPage=()=>{footer();page=pdf.addPage([width,height]);pageNumber++;y=height-58};
  const wrap=(text:string,size:number,fontRef:any)=>{const words=String(text).replace(/\r/g,"").split(/\s+/),lines:string[]=[];let line="";for(const word of words){const candidate=line?`${line} ${word}`:word;if(fontRef.widthOfTextAtSize(candidate,size)<=maxWidth)line=candidate;else{if(line)lines.push(line);line=word}}if(line)lines.push(line);return lines};
  const drawParagraph=(text:string,size=10.5,fontRef=font,gap=8)=>{for(const paragraph of String(text).split(/\n+/)){const lines=wrap(paragraph,size,fontRef);for(const line of lines){if(y<70)nextPage();page.drawText(line,{x:margin,y,size,font:fontRef,color:rgb(.08,.08,.08)});y-=lineHeight}y-=gap}};
  page.drawText("ARBEIDSAVTALE",{x:margin,y,size:20,font:bold,color:rgb(.06,.14,.12)});y-=34;
  drawParagraph(`Arbeidsgiver: ${employerName}`,10,font,5);
  drawParagraph(`Arbeidstaker: ${employee.full_name} | ${[employee.address,[employee.postal_code,employee.city].filter(Boolean).join(" ")].filter(Boolean).join(", ")} | E-post: ${employee.email}${employee.phone_number?` | Telefon: ${employee.phone_number}`:""}`,10,font,16);
  const modules=(contract.locked_modules||contract.modules||[]).filter((m:ContractModule)=>m.active);
  modules.forEach((m:ContractModule,index:number)=>{if(y<120)nextPage();drawParagraph(`${index+1} ${m.title}`,14,bold,7);drawParagraph(contractText(m.body,employee),10.5,font,14)});
  if(y<190)nextPage();y-=12;page.drawLine({start:{x:margin,y},end:{x:margin+190,y},thickness:.8,color:rgb(.25,.25,.25)});page.drawLine({start:{x:width-margin-190,y},end:{x:width-margin,y},thickness:.8,color:rgb(.25,.25,.25)});y-=18;
  page.drawText("Sted, dato og arbeidsgivers signatur",{x:margin,y,size:9,font});page.drawText("Sted, dato og arbeidstakers signatur",{x:width-margin-190,y,size:9,font});footer();
  const bytes=await pdf.save();let binary="";for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.slice(i,i+8192));return btoa(binary);
};
